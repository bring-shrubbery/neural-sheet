import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

/// Deterministic pseudo-random source, so a failure is always reproducible.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `[-1, 1)`.
    mutating func nextSample() -> Float {
        Float(next() >> 40) / Float(1 << 23) - 1.0
    }

    mutating func nextInt(below bound: Int) -> Int {
        Int(next() >> 1) % bound
    }
}

/// The answer a naive scan gives, which the pyramid must contain.
private func bruteForce(_ samples: [Float], _ startSample: Int, _ endSample: Int) -> PeakPair {
    let start = Swift.max(0, startSample)
    let end = Swift.min(samples.count, endSample)
    guard start < end else { return .empty }

    var result = PeakPair.empty
    for i in start..<end {
        result.min = Swift.min(result.min, samples[i])
        result.max = Swift.max(result.max, samples[i])
    }
    return result
}

/// How many levels a pyramid over `sampleCount` samples has, derived independently of the
/// implementation: level 0 is one bin per 64 samples, each level halves, the top level is one bin.
private func levelCount(forSampleCount sampleCount: Int) -> Int {
    guard sampleCount > 0 else { return 0 }
    var bins = (sampleCount + WaveformPeaks.baseBinSamples - 1) / WaveformPeaks.baseBinSamples
    var levels = 1
    while bins > 1 {
        bins = (bins + 1) / 2
        levels += 1
    }
    return levels
}

private func ramp(_ count: Int) -> [Float] {
    (0..<count).map { Float($0) / Float(count) }
}

private func randomSamples(_ count: Int, seed: UInt64) -> [Float] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { _ in rng.nextSample() }
}

// MARK: - Tests

@Test func firstBinQueryMatchesRawScan() {
    let samples = ramp(1000)
    let peaks = WaveformPeaks()
    peaks.build(from: samples)

    #expect(peaks.sampleCount == 1000)

    let result = peaks.peaks(from: 0, to: WaveformPeaks.baseBinSamples)
    let expected = bruteForce(samples, 0, WaveformPeaks.baseBinSamples)

    #expect(result == expected)
    #expect(result.min == samples[0])
    #expect(result.max == samples[WaveformPeaks.baseBinSamples - 1])
}

@Test func shortQueriesAreExactAfterBuild() {
    let samples = randomSamples(50_000, seed: 11)
    let peaks = WaveformPeaks()
    peaks.build(from: samples)

    var rng = SplitMix64(seed: 12)
    for _ in 0..<20 {
        let start = rng.nextInt(below: samples.count - WaveformPeaks.rawScanMaxSamples)
        let span = 1 + rng.nextInt(below: WaveformPeaks.rawScanMaxSamples)
        let result = peaks.peaks(from: start, to: start + span)
        // A span of at most rawScanMaxSamples reads the retained samples, so it is exact.
        #expect(result == bruteForce(samples, start, start + span))
    }
}

@Test func pyramidQueriesContainBruteForceOverRandomSpans() {
    let samples = randomSamples(300_000, seed: 21)
    let peaks = WaveformPeaks()
    peaks.build(from: samples)

    var rng = SplitMix64(seed: 22)
    for _ in 0..<20 {
        let start = rng.nextInt(below: samples.count)
        let end = start + 1 + rng.nextInt(below: samples.count - start)
        let result = peaks.peaks(from: start, to: end)
        let expected = bruteForce(samples, start, end)

        #expect(!result.isEmpty)
        // Coarsening may widen the answer (whole bins are included) but must never lose a peak.
        #expect(result.min <= expected.min)
        #expect(result.max >= expected.max)
    }
}

@Test func queryPicksCoarsestLevelWhoseBinsAreSmallEnough() {
    let sampleCount = 300_000
    let samples = randomSamples(sampleCount, seed: 31)
    let peaks = WaveformPeaks()
    peaks.build(from: samples)

    let levels = levelCount(forSampleCount: sampleCount)
    var rng = SplitMix64(seed: 32)

    // Spans straddling the level boundaries (binSamples * 16 <= span), plus random wide ones.
    var spans = [2049, 2048 * 2, 2048 * 2 + 1, 4096, 20_480, 100_000, sampleCount]
    for _ in 0..<10 {
        spans.append(WaveformPeaks.rawScanMaxSamples + 1 + rng.nextInt(below: 200_000))
    }

    for span in spans {
        let start = rng.nextInt(below: Swift.max(1, sampleCount - 1))
        let end = Swift.min(sampleCount, start + span)
        guard end - start > WaveformPeaks.rawScanMaxSamples else { continue }
        let clampedSpan = end - start

        // Reproduce the documented rule here, independently of the implementation.
        var level = 0
        while level + 1 < levels,
            (WaveformPeaks.baseBinSamples << (level + 1)) * WaveformPeaks.minBinsPerQuery <= clampedSpan
        {
            level += 1
        }

        let binSamples = WaveformPeaks.baseBinSamples << level
        let firstBin = start / binSamples
        let lastBin = (end - 1) / binSamples
        // Bins are included whole, so the answer equals a scan over the bins' full sample range.
        let expected = bruteForce(
            samples, firstBin * binSamples, Swift.min(sampleCount, (lastBin + 1) * binSamples))

        #expect(peaks.peaks(from: start, to: end) == expected)
    }
}

@Test func appendInChunksEqualsOneBuild() {
    let samples = randomSamples(30_000, seed: 41)

    let built = WaveformPeaks()
    built.build(from: samples)

    let appended = WaveformPeaks()
    var offset = 0
    while offset < samples.count {
        let end = Swift.min(samples.count, offset + 100)
        appended.append(Array(samples[offset..<end]))
        offset = end
    }

    #expect(appended.sampleCount == built.sampleCount)

    // The top-level peak: one bin covering everything.
    #expect(appended.peaks(from: 0, to: samples.count) == built.peaks(from: 0, to: samples.count))

    // And the whole pyramid agrees, at every level a query can settle on. Spans wider than
    // rawScanMaxSamples keep the built instance off its raw-sample fast path, so both read bins.
    var rng = SplitMix64(seed: 42)
    for _ in 0..<20 {
        let start = rng.nextInt(below: samples.count - WaveformPeaks.rawScanMaxSamples - 1)
        let span = WaveformPeaks.rawScanMaxSamples + 1 + rng.nextInt(below: 10_000)
        let end = Swift.min(samples.count, start + span)
        #expect(appended.peaks(from: start, to: end) == built.peaks(from: start, to: end))
    }
}

@Test func appendUnionsIntoPartiallyFilledBins() {
    // Two appends that both land inside level-0 bin 0: the bin must keep both extremes.
    let peaks = WaveformPeaks()
    peaks.append([0.5, -0.25])
    peaks.append([-0.75, 0.1])

    #expect(peaks.sampleCount == 4)
    let result = peaks.peaks(from: 0, to: 4)
    #expect(result.min == -0.75)
    #expect(result.max == 0.5)
}

@Test func clearResetsEverything() {
    let peaks = WaveformPeaks()
    peaks.build(from: ramp(5000))
    peaks.clear()

    #expect(peaks.sampleCount == 0)
    #expect(peaks.peaks(from: 0, to: 5000).isEmpty)
}

@Test func emptyAndOutOfRangeQueriesAreEmpty() {
    let peaks = WaveformPeaks()
    #expect(peaks.peaks(from: 0, to: 100).isEmpty)

    peaks.build(from: ramp(1000))
    #expect(peaks.peaks(from: 500, to: 500).isEmpty)
    #expect(peaks.peaks(from: 2000, to: 3000).isEmpty)
    #expect(peaks.peaks(from: 900, to: 5000) == bruteForce(ramp(1000), 900, 1000))
    #expect(peaks.peaks(from: -100, to: 64) == bruteForce(ramp(1000), 0, 64))
}

@Test func buildFromEmptyIsEmpty() {
    let peaks = WaveformPeaks()
    peaks.build(from: [])
    #expect(peaks.sampleCount == 0)
    #expect(peaks.peaks(from: 0, to: 1).isEmpty)
}

@Test func snapshotMatchesLiveQueriesAndIsStable() {
    let samples = randomSamples(40_000, seed: 51)
    let peaks = WaveformPeaks()
    peaks.build(from: samples)

    let snapshot = peaks.snapshot()
    #expect(snapshot.sampleCount == peaks.sampleCount)

    var rng = SplitMix64(seed: 52)
    var spans: [(Int, Int)] = []
    for _ in 0..<20 {
        let start = rng.nextInt(below: samples.count - 1)
        let end = start + 1 + rng.nextInt(below: samples.count - start)
        spans.append((start, end))
        #expect(snapshot.peaks(from: start, to: end) == peaks.peaks(from: start, to: end))
    }

    // The snapshot is a value: growing the source must not change what it already answered.
    let answers = spans.map { snapshot.peaks(from: $0.0, to: $0.1) }
    peaks.append([Float](repeating: 2.0, count: 10_000))

    #expect(snapshot.sampleCount == 40_000)
    for (span, answer) in zip(spans, answers) {
        #expect(snapshot.peaks(from: span.0, to: span.1) == answer)
    }
}

@Test func concurrentAppendsAndQueriesAreSafe() async {
    let peaks = WaveformPeaks()
    let chunk = [Float](repeating: 0.25, count: 512)

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for _ in 0..<200 { peaks.append(chunk) }
        }
        group.addTask {
            for _ in 0..<200 {
                let snapshot = peaks.snapshot()
                _ = snapshot.peaks(from: 0, to: snapshot.sampleCount)
                _ = peaks.peaks(from: 0, to: peaks.sampleCount)
            }
        }
    }

    #expect(peaks.sampleCount == 200 * 512)
    let result = peaks.peaks(from: 0, to: peaks.sampleCount)
    #expect(result.min == 0.25)
    #expect(result.max == 0.25)
}
