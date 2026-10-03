import Accelerate
import Foundation

/// What ``TempoEstimator`` found: a whole-number tempo, the earliest downbeat at or after the
/// start of the take, and the tempo map the beats fold into (tempo map design §3) with the meter
/// when the accents were clear.
public struct TempoEstimate: Equatable, Sendable {
    public var bpm: Double
    public var downbeatSeconds: Double
    /// From bar 1 at `downbeatSeconds`; one segment at `bpm` when the beats gave too little.
    public var segments: [GridSegment]
    /// 3/4 or 4/4 when the accents said so; nil leaves the meter as it was.
    public var timeSignature: TimeSignature?

    public init(bpm: Double, downbeatSeconds: Double, segments: [GridSegment]? = nil, timeSignature: TimeSignature? = nil) {
        self.bpm = bpm
        self.downbeatSeconds = downbeatSeconds
        self.segments = segments ?? [GridSegment(startBar: 1, bpm: bpm, timeSignature: timeSignature ?? .common)]
        self.timeSignature = timeSignature
    }
}

/// The tempo and a downbeat from the take's audio (tempo design §3.2): an onset-strength
/// envelope, its autocorrelation under a prior about 120 BPM, then the beat phase and the
/// strongest of a bar's beat phases. Then the tempo map (tempo map design §2): the beats tracked
/// through the take (`BeatTracker`), the meter from their accents (`MeterEstimator`) and the bars
/// folded into segments (`TempoMapBuilder`). Any thread; allocates freely.
public enum TempoEstimator {
    /// The model's mono copy is what is analysed.
    public static let sampleRate = 16_000.0
    /// 80 samples at 16 kHz: a 200 Hz envelope, 5 ms per frame.
    public static let hop = 80
    public static let window = 512
    /// Frames per second of the envelope.
    public static var envelopeRate: Double { sampleRate / Double(hop) }

    public static let minBpm = 40.0
    public static let maxBpm = 240.0
    /// Octave folds land the result in here.
    public static let foldLow = 60.0
    public static let foldHigh = 200.0
    /// The prior's centre and its width in octaves.
    static let priorBpm = 120.0
    static let priorOctaves = 1.0

    /// The least audio worth analysing.
    public static let minimumSeconds = 4.0

    /// - Parameter meter: the meter the bars are counted in when the accents do not settle it.
    public static func estimate(mono16k: [Float], meter: TimeSignature = .common) -> TempoEstimate? {
        guard Double(mono16k.count) / sampleRate >= minimumSeconds else { return nil }

        let envelope = onsetEnvelope(mono16k)

        guard let bpm = tempo(from: envelope) else { return nil }

        let beats = BeatTracker.track(envelope: envelope, bpm: bpm)
        let detected = MeterEstimator.estimate(envelope: envelope, beats: beats)
        let counted = detected ?? meter
        let beatsPerBar = counted.isCompound ? counted.numerator / 3 : counted.numerator
        let downbeatIndex = MeterEstimator.downbeatIndex(envelope: envelope, beats: beats, beatsPerBar: beatsPerBar)

        guard let map = TempoMapBuilder.build(beats: beats, downbeatIndex: downbeatIndex, timeSignature: counted) else {
            // Too few bars to read a map from: the single estimate, as before the map.
            let downbeat = downbeat(in: envelope, bpm: bpm, beatsPerBar: max(1, beatsPerBar))
            return TempoEstimate(bpm: bpm, downbeatSeconds: downbeat,
                                 segments: [GridSegment(startBar: 1, bpm: bpm, timeSignature: counted)], timeSignature: detected)
        }

        return TempoEstimate(bpm: bpm, downbeatSeconds: map.offset, segments: map.segments, timeSignature: detected)
    }

    // MARK: - Onset envelope

    /// Spectral flux at 200 Hz: the rectified rise of each bin's compressed magnitude from one
    /// frame to the next, summed; then less a ±0.5 s moving mean and rectified again, so slow
    /// swells do not read as beats; then smoothed over three frames.
    static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        guard samples.count >= window else { return [] }

        let frameCount = (samples.count - window) / hop + 1
        let bins = window / 2
        let log2n = vDSP_Length(log2(Double(window)))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: window)
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: window)
        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var magnitudes = [Float](repeating: 0, count: bins)
        var previous = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: frameCount)

        samples.withUnsafeBufferPointer { input in
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)

                    for frame in 0..<frameCount {
                        let start = frame * hop

                        vDSP_vmul(input.baseAddress! + start, 1, hann, 1, &windowed, 1, vDSP_Length(window))

                        windowed.withUnsafeBufferPointer { w in
                            w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
                            }
                        }

                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(bins))

                        var sum: Float = 0
                        for bin in 1..<bins {
                            let compressed = log(1 + 1000 * magnitudes[bin])
                            let rise = compressed - previous[bin]
                            if rise > 0 { sum += rise }
                            previous[bin] = compressed
                        }

                        flux[frame] = sum
                    }
                }
            }
        }

        return smoothed(detrended(flux, halfSpan: Int(envelopeRate / 2)), span: 3)
    }

    /// `x` less its moving mean over ±`halfSpan`, rectified.
    static func detrended(_ x: [Float], halfSpan: Int) -> [Float] {
        guard !x.isEmpty else { return x }

        var prefix = [Double](repeating: 0, count: x.count + 1)
        for (index, value) in x.enumerated() {
            prefix[index + 1] = prefix[index] + Double(value)
        }

        return (0..<x.count).map { index in
            let low = max(0, index - halfSpan)
            let high = min(x.count, index + halfSpan + 1)
            let mean = Float((prefix[high] - prefix[low]) / Double(high - low))

            return max(0, x[index] - mean)
        }
    }

    /// A centred moving mean over `span` frames.
    static func smoothed(_ x: [Float], span: Int) -> [Float] {
        guard x.count > span, span > 1 else { return x }

        let half = span / 2

        return (0..<x.count).map { index in
            let low = max(0, index - half)
            let high = min(x.count - 1, index + half)
            var sum: Float = 0
            for i in low...high { sum += x[i] }
            return sum / Float(high - low + 1)
        }
    }

    // MARK: - Tempo

    /// The BPM whose lag the envelope's autocorrelation, under the prior, peaks at; nil for an
    /// envelope too short to hold the slowest lag twice, or one with nothing in it.
    static func tempo(from envelope: [Float]) -> Double? {
        let minLag = Int((envelopeRate * 60 / maxBpm).rounded())
        let maxLag = Int((envelopeRate * 60 / minBpm).rounded())

        guard envelope.count > 2 * maxLag, envelope.contains(where: { $0 > 0 }) else { return nil }

        let n = envelope.count
        var scores = [Double](repeating: 0, count: maxLag + 2)
        let centreLag = envelopeRate * 60 / priorBpm

        envelope.withUnsafeBufferPointer { e in
            for lag in (minLag - 1)...(maxLag + 1) where lag > 0 && lag < n {
                var dot: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))

                let octaves = log2(Double(lag) / centreLag) / priorOctaves
                let prior = exp(-0.5 * octaves * octaves)

                scores[lag] = Double(dot) / Double(n - lag) * prior
            }
        }

        var bestLag = minLag
        for lag in minLag...maxLag where scores[lag] > scores[bestLag] {
            bestLag = lag
        }

        guard scores[bestLag] > 0 else { return nil }

        // A parabola through the peak and its neighbours puts the lag between frames.
        var lag = Double(bestLag)
        if bestLag > minLag - 1, bestLag < maxLag + 1 {
            let left = scores[bestLag - 1]
            let centre = scores[bestLag]
            let right = scores[bestLag + 1]
            let denominator = left - 2 * centre + right

            if denominator < 0 {
                lag += 0.5 * (left - right) / denominator
            }
        }

        var bpm = envelopeRate * 60 / lag
        while bpm < foldLow { bpm *= 2 }
        while bpm >= foldHigh { bpm /= 2 }

        return bpm.rounded()
    }

    // MARK: - Downbeat

    /// The beat phase as the fullest of `⌈τ⌉` bins the envelope folds into at the beat period,
    /// then the one of a bar's `beatsPerBar` beats whose bar-period comb collects the most; in
    /// seconds.
    static func downbeat(in envelope: [Float], bpm: Double, beatsPerBar: Int = 4) -> Double {
        let period = envelopeRate * 60 / bpm

        guard period > 1, envelope.count > 1 else { return 0 }

        let beatBins = Int(period.rounded(.up))
        var beat = [Double](repeating: 0, count: beatBins)

        for (index, value) in envelope.enumerated() {
            let bin = Int(Double(index).truncatingRemainder(dividingBy: period).rounded()) % beatBins
            beat[bin] += Double(value)
        }

        var phase = 0
        for bin in 1..<beatBins where beat[bin] > beat[phase] {
            phase = bin
        }

        // Which of the bar's beats: the comb at the bar period, ±1 frame, that collects the most
        // from each candidate phase.
        let bar = period * Double(beatsPerBar)
        var bestBeat = 0
        var bestEnergy = -1.0

        for m in 0..<beatsPerBar {
            let start = Double(phase) + Double(m) * period
            var energy = 0.0
            var position = start

            while position < Double(envelope.count) {
                let centre = Int(position.rounded())
                for offset in -1...1 {
                    let index = centre + offset
                    if index >= 0, index < envelope.count { energy += Double(envelope[index]) }
                }
                position += bar
            }

            if energy > bestEnergy {
                bestEnergy = energy
                bestBeat = m
            }
        }

        // A frame's flux peaks with the onset under the window's centre, so a frame stands for
        // the time half a window past its start.
        return (Double(phase) + Double(bestBeat) * period) / envelopeRate + frameCentreOffset
    }

    /// Seconds from a frame's first sample to the time it stands for.
    static var frameCentreOffset: Double { Double(window) / 2 / sampleRate }
}
