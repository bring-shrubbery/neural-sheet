import Accelerate
import Foundation

/// The vertical extent of one slice of audio. An empty slice has `min > max`.
public struct PeakPair: Equatable, Sendable {
    public var min: Float
    public var max: Float

    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }

    /// The identity of `formUnion`: nothing at all.
    public static let empty = PeakPair(min: .greatestFiniteMagnitude, max: -.greatestFiniteMagnitude)

    public var isEmpty: Bool { min > max }

    public mutating func formUnion(_ other: PeakPair) {
        min = Swift.min(min, other.min)
        max = Swift.max(max, other.max)
    }

    public func union(_ other: PeakPair) -> PeakPair {
        var result = self
        result.formUnion(other)
        return result
    }
}

/// Peaks over a run of samples, as one bin's worth.
@inline(__always)
private func scan(_ samples: ArraySlice<Float>) -> PeakPair {
    guard !samples.isEmpty else { return .empty }

    var low: Float = 0
    var high: Float = 0

    samples.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        vDSP_minv(base, 1, &low, vDSP_Length(buffer.count))
        vDSP_maxv(base, 1, &high, vDSP_Length(buffer.count))
    }

    return PeakPair(min: low, max: high)
}

/// The query shared by ``WaveformPeaks`` and ``WaveformPeaksSnapshot``.
///
/// - Parameters:
///   - levels: `levels[k]` has bins of `baseBinSamples << k`; the top level is a single bin.
///   - rawSamples: the audio the peaks were built from, empty once peaks have been appended.
private func query(
    levels: [[PeakPair]],
    rawSamples: [Float],
    sampleCount: Int,
    from startSample: Int,
    to endSample: Int
) -> PeakPair {
    let start = Swift.max(0, startSample)
    let end = Swift.min(endSample, sampleCount)

    guard end > start, !levels.isEmpty else { return .empty }

    let span = end - start

    if !rawSamples.isEmpty && span <= WaveformPeaks.rawScanMaxSamples {
        return scan(rawSamples[start..<end])
    }

    // The coarsest level whose bins are still small enough that including them whole cannot widen
    // the answer by much.
    var level = 0
    while level + 1 < levels.count,
        (WaveformPeaks.baseBinSamples << (level + 1)) * WaveformPeaks.minBinsPerQuery <= span
    {
        level += 1
    }

    let binSamples = WaveformPeaks.baseBinSamples << level
    let bins = levels[level]

    // Floor at both ends, so every bin the range touches is included. Erring wide keeps a transient
    // that straddles a bin boundary; erring narrow would drop it, which is what looks broken.
    let firstBin = start / binSamples
    let lastBin = Swift.min((end - 1) / binSamples, bins.count - 1)

    guard firstBin <= lastBin else { return .empty }

    var result = PeakPair.empty
    for bin in firstBin...lastBin {
        result.formUnion(bins[bin])
    }
    return result
}

/// An immutable view of a pyramid, for a paint pass that must see one consistent signal.
///
/// Taking a snapshot copies three arrays' references, not their contents, so a frame pays for the
/// lock once and then queries freely while the recorder keeps appending.
public struct WaveformPeaksSnapshot: Sendable {
    fileprivate let levels: [[PeakPair]]
    fileprivate let rawSamples: [Float]

    /// How many samples the peaks cover.
    public let sampleCount: Int

    fileprivate init(levels: [[PeakPair]], rawSamples: [Float], sampleCount: Int) {
        self.levels = levels
        self.rawSamples = rawSamples
        self.sampleCount = sampleCount
    }

    /// Peaks over `[from, to)`, clamped to what exists. Empty if nothing does.
    public func peaks(from startSample: Int, to endSample: Int) -> PeakPair {
        query(
            levels: levels, rawSamples: rawSamples, sampleCount: sampleCount,
            from: startSample, to: endSample)
    }
}

/// Min/max peaks over a mono signal, stored as a pyramid so a query costs the same however much
/// audio it spans.
///
/// Level 0 holds one min/max per ``baseBinSamples``; each level above combines pairs from the one
/// below. A query picks the coarsest level whose bins are small enough to keep the answer tight, so
/// a bar spanning ten minutes reads about as many bins as one spanning a second. Below
/// ``rawScanMaxSamples`` it reads the samples themselves and is exact.
///
/// Peaks are appended from the audio thread while recording and read from the main actor while
/// painting, so every access is locked; ``snapshot()`` hands a whole frame one consistent value
/// rather than making it lock per query.
public final class WaveformPeaks: @unchecked Sendable {
    /// 4 ms at 16 kHz. Finer than one bar at any zoom the UI offers.
    public static let baseBinSamples = 64
    /// How many bins a query reads at the level it settles on. Bins are included whole, so a query
    /// covers up to one extra bin at each end -- this bounds that overshoot to 1/8 of the range.
    public static let minBinsPerQuery = 16
    /// Below this, a query scans the samples directly instead: 64-sample bins are too coarse once a
    /// bar is only a couple of hundred samples wide, and scanning is cheap at that size anyway.
    public static let rawScanMaxSamples = 2048

    private let lock = NSLock()

    /// `levels[k]` has bins of `baseBinSamples << k`. The top level is a single bin.
    private var levels: [[PeakPair]] = []

    /// The audio the peaks were built from. Empty while recording, which is what makes queries fall
    /// back to the pyramid at every zoom.
    private var rawSamples: [Float] = []

    private var count = 0

    public init() {}

    /// How many samples the peaks cover.
    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Replaces the contents with peaks over the whole of `samples`.
    ///
    /// The samples are kept, which is what lets queries be exact when zoomed in.
    public func build(from samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        levels.removeAll(keepingCapacity: true)
        rawSamples = samples
        count = samples.count

        guard count > 0 else {
            rawSamples = []
            return
        }

        let binCount = (count + Self.baseBinSamples - 1) / Self.baseBinSamples
        var level0 = [PeakPair](repeating: .empty, count: binCount)

        for bin in 0..<binCount {
            let start = bin * Self.baseBinSamples
            let end = Swift.min(start + Self.baseBinSamples, count)
            level0[bin] = scan(samples[start..<end])
        }

        levels.append(level0)

        // Every level above is pairs of the one below, up to a single bin covering everything.
        while levels[levels.count - 1].count > 1 {
            let below = levels[levels.count - 1]
            var level = [PeakPair](repeating: .empty, count: (below.count + 1) / 2)

            for bin in 0..<level.count {
                var value = below[bin * 2]
                if bin * 2 + 1 < below.count {
                    value.formUnion(below[bin * 2 + 1])
                }
                level[bin] = value
            }

            levels.append(level)
        }
    }

    /// Extends the peaks, for a recording that is still growing. No samples are retained.
    ///
    /// Appending in chunks gives the same pyramid as one ``build(from:)`` over the concatenation.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // A growing recording has no buffer to scan, so drop any retained one rather than let a
        // query read samples that no longer line up with the peaks.
        rawSamples = []

        if levels.isEmpty {
            levels.append([])
        }

        let start = count
        let end = start + samples.count
        let firstBin = start / Self.baseBinSamples
        let lastBin = (end - 1) / Self.baseBinSamples

        if levels[0].count < lastBin + 1 {
            levels[0].append(
                contentsOf: [PeakPair](repeating: .empty, count: lastBin + 1 - levels[0].count))
        }

        // The bin the previous append stopped part-way through is unioned into rather than
        // overwritten, which is what makes appending in chunks equivalent to one pass.
        for bin in firstBin...lastBin {
            let binStart = Swift.max(start, bin * Self.baseBinSamples)
            let binEnd = Swift.min(end, (bin + 1) * Self.baseBinSamples)
            levels[0][bin].formUnion(
                scan(samples[(binStart - start) ..< (binEnd - start)]))
        }

        count = end

        cascade(firstBin: firstBin, lastBin: lastBin)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        levels.removeAll(keepingCapacity: true)
        rawSamples = []
        count = 0
    }

    /// Peaks over `[from, to)`, clamped to what exists. Empty if nothing does.
    public func peaks(from startSample: Int, to endSample: Int) -> PeakPair {
        lock.lock()
        defer { lock.unlock() }

        return query(
            levels: levels, rawSamples: rawSamples, sampleCount: count,
            from: startSample, to: endSample)
    }

    /// An immutable copy for a paint pass: every query it serves sees the same audio.
    public func snapshot() -> WaveformPeaksSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return WaveformPeaksSnapshot(levels: levels, rawSamples: rawSamples, sampleCount: count)
    }

    /// Recomputes levels above 0 for the bins covering `[firstBin, lastBin]` at level 0.
    private func cascade(firstBin: Int, lastBin: Int) {
        var firstBin = firstBin
        var lastBin = lastBin
        var level = 1

        while levels[level - 1].count > 1 {
            if levels.count <= level {
                levels.append([])
            }

            firstBin /= 2
            lastBin /= 2

            let below = levels[level - 1]

            if levels[level].count < lastBin + 1 {
                levels[level].append(
                    contentsOf: [PeakPair](
                        repeating: .empty, count: lastBin + 1 - levels[level].count))
            }

            for bin in firstBin...lastBin {
                var value = below[bin * 2]
                if bin * 2 + 1 < below.count {
                    value.formUnion(below[bin * 2 + 1])
                }
                levels[level][bin] = value
            }

            level += 1
        }
    }
}
