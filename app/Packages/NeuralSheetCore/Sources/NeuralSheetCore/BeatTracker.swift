import Accelerate
import Foundation

/// Beats through the whole take (tempo map design §2): Ellis's dynamic-programming tracker over
/// ``TempoEstimator``'s 200 Hz onset envelope. A beat at frame `t` scores the envelope there plus
/// the best of the beats before it, each less `α · log²(interval / period)`, so the track holds to
/// the period without being forced onto it; the best final frame is followed back to the first.
///
/// The period is local. It is re-estimated every half second from the envelope's autocorrelation
/// over the 8 s before and the 8 s after, and an interval is judged by whichever of the two it
/// fits better: within a steady stretch they agree, and at a tempo change one side always holds
/// the new tempo, so a ritardando or a step from 120 to 90 is followed rather than fought. Any
/// thread; allocates freely.
public enum BeatTracker {
    /// librosa's tightness of 100, scaled to this envelope rate.
    static let tightness = 680.0
    /// The local period's window on each side, and how often it is re-estimated.
    static let windowSeconds = 8.0
    static let hopSeconds = 0.5
    /// How far the local period may stray from the take's, as a ratio either way: a rubato or a
    /// change of tempo, never an octave.
    static let periodRange = 1.5

    /// Beat times in seconds, ascending; empty for an envelope with nothing in it.
    public static func track(envelope: [Float], bpm: Double) -> [Double] {
        frames(envelope: envelope, bpm: bpm).map { Double($0) / TempoEstimator.envelopeRate + TempoEstimator.frameCentreOffset }
    }

    /// The beats as envelope frames.
    static func frames(envelope: [Float], bpm: Double) -> [Int] {
        let count = envelope.count
        let period = TempoEstimator.envelopeRate * 60 / bpm

        guard count > 1, period > 2, bpm.isFinite else { return [] }

        // The envelope in units of its own spread, as librosa scores it, so the tightness means
        // the same whatever the take's level.
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(envelope, 1, nil, 1, &mean, &deviation, vDSP_Length(count))

        guard deviation > 0 else { return [] }

        let local = envelope.map { Double($0 / deviation) }
        let periods = localPeriods(envelope: envelope, period: period)
        var score = [Double](repeating: 0, count: count)
        var back = [Int](repeating: -1, count: count)

        for t in 0..<count {
            let (before, after) = periods.at(frame: t)
            let earliest = t - Int((2 * max(before, after)).rounded())
            let latest = t - Int((min(before, after) / 2).rounded())
            var best = 0.0
            var bestFrame = -1

            if latest >= 0 {
                for p in max(0, earliest)...latest {
                    let interval = Double(t - p)
                    let offBefore = log(interval / before)
                    let offAfter = log(interval / after)
                    let candidate = score[p] - tightness * min(offBefore * offBefore, offAfter * offAfter)

                    if candidate > best {
                        best = candidate
                        bestFrame = p
                    }
                }
            }

            // A chain that costs more than it brings starts afresh here instead.
            score[t] = local[t] + best
            back[t] = bestFrame
        }

        // The best frame within a period of the end, then back to the first beat.
        let tail = max(0, count - Int(period.rounded(.up)))
        var frame = (tail..<count).max { score[$0] < score[$1] } ?? count - 1
        var beats: [Int] = []

        while frame >= 0 {
            beats.append(frame)
            frame = back[frame]
        }

        return trimmed(beats.reversed(), envelope: envelope)
    }

    /// Without the beats laid over silence before the first onset and after the last: those
    /// whose envelope is under a quarter of the beats' median.
    static func trimmed(_ beats: [Int], envelope: [Float]) -> [Int] {
        let strengths = beats.map { strength(at: $0, in: envelope) }

        guard let median = strengths.sorted().dropFirst(strengths.count / 2).first, median > 0 else { return beats }

        let threshold = median / 4

        guard let first = strengths.firstIndex(where: { $0 >= threshold }),
              let last = strengths.lastIndex(where: { $0 >= threshold }) else { return [] }

        return Array(beats[first...last])
    }

    /// The envelope's peak within two frames of `frame`: a beat placed a frame off its onset
    /// still reads the onset.
    static func strength(at frame: Int, in envelope: [Float]) -> Float {
        let low = max(0, frame - 2)
        let high = min(envelope.count - 1, frame + 2)

        guard low <= high else { return 0 }

        return envelope[low...high].max() ?? 0
    }

    // MARK: - Local period

    /// The period estimated at every hop, each over the window before it and the window after.
    struct LocalPeriods {
        var hop: Int
        /// `[i]` is over the window ending at hop `i` and starting at it, in frames.
        var before: [Double]
        var after: [Double]

        /// The estimate behind `frame` from the last hop at or before it, and the one ahead
        /// from the first hop at or after it.
        func at(frame: Int) -> (before: Double, after: Double) {
            let below = min(frame / hop, before.count - 1)
            let above = min((frame + hop - 1) / hop, after.count - 1)

            return (before[below], after[above])
        }
    }

    static func localPeriods(envelope: [Float], period: Double) -> LocalPeriods {
        let rate = TempoEstimator.envelopeRate
        let hop = max(1, Int(hopSeconds * rate))
        let window = Int(windowSeconds * rate)
        let hops = envelope.count / hop + 1

        let estimates = (0..<hops).map { index -> (Double, Double) in
            let centre = index * hop
            let before = bestLag(envelope, from: centre - window, to: centre, around: period)
            let after = bestLag(envelope, from: centre, to: centre + window, around: period)

            return (before ?? after ?? period, after ?? before ?? period)
        }

        return LocalPeriods(hop: hop, before: estimates.map(\.0), after: estimates.map(\.1))
    }

    /// The lag within `periodRange` of `period` where the autocorrelation of `envelope[from..<to]`
    /// peaks, leaning gently towards `period`; nil for a stretch too short or too quiet to say.
    static func bestLag(_ envelope: [Float], from: Int, to: Int, around period: Double) -> Double? {
        let low = max(0, from)
        let high = min(envelope.count, to)
        let minLag = max(1, Int((period / periodRange).rounded(.down)))
        let maxLag = Int((period * periodRange).rounded(.up))

        guard high - low > 2 * maxLag else { return nil }

        var best: Double?
        var bestScore = 0.0

        envelope.withUnsafeBufferPointer { e in
            let base = e.baseAddress! + low
            let length = high - low

            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(length - lag))

                let octaves = log2(Double(lag) / period)
                let score = Double(dot) / Double(length - lag) * exp(-2 * octaves * octaves)

                if score > bestScore {
                    bestScore = score
                    best = Double(lag)
                }
            }
        }

        return best
    }
}
