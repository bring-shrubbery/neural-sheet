import Foundation

/// One section of an IIR cascade, in transposed direct form II (the form JUCE's `dsp::IIR::Filter`
/// uses, so the arithmetic matches sample for sample).
struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    private var state0: Float = 0
    private var state1: Float = 0

    /// A second-order low-pass by the bilinear transform, matching JUCE's
    /// `IIR::ArrayCoefficients::makeLowPass`.
    init(lowPassFrequency frequency: Double, sampleRate: Double, q: Double) {
        let n = 1.0 / tan(Double.pi * frequency / sampleRate)
        let nSquared = n * n
        let invQ = 1.0 / q
        let c1 = 1.0 / (1.0 + invQ * n + nSquared)

        b0 = Float(c1)
        b1 = Float(c1 * 2.0)
        b2 = Float(c1)
        a1 = Float(c1 * 2.0 * (1.0 - nSquared))
        a2 = Float(c1 * (1.0 - invQ * n + nSquared))
    }

    mutating func reset() {
        state0 = 0
        state1 = 0
    }

    mutating func process(_ sample: Float) -> Float {
        let output = b0 * sample + state0
        state0 = b1 * sample - a1 * output + state1
        state1 = b2 * sample - a2 * output
        return output
    }

    /// An even-order Butterworth low-pass as a cascade of biquads, matching JUCE's
    /// `FilterDesign::designIIRLowpassHighOrderButterworthMethod`: the poles sit on a half circle,
    /// so each section only differs in its Q.
    static func butterworthLowPass(frequency: Double, sampleRate: Double, order: Int) -> [Biquad] {
        precondition(order > 0 && order % 2 == 0, "only even Butterworth orders are supported")

        return (0..<(order / 2)).map { i in
            let q = 1.0 / (2.0 * cos((2.0 * Double(i) + 1.0) * Double.pi / (Double(order) * 2.0)))
            return Biquad(lowPassFrequency: frequency, sampleRate: sampleRate, q: q)
        }
    }
}

/// 4-point Lagrange interpolation over a stream, mirroring JUCE's `LagrangeInterpolator`.
///
/// The five most recent input samples sit in a ring buffer and the fractional read position is
/// carried between calls, so a signal fed in blocks resamples exactly as if it arrived in one.
struct LagrangeInterpolator {
    /// How many samples the ring holds.
    static let memorySize = 5
    /// The interpolator reads two samples ahead of the position it reports, so a stream is primed
    /// with this many zeros.
    static let baseLatency = 2

    private var buffer = [Float](repeating: 0, count: LagrangeInterpolator.memorySize)
    private var index = 0
    private var subSamplePosition: Double = 1.0

    mutating func reset() {
        buffer = [Float](repeating: 0, count: Self.memorySize)
        index = 0
        subSamplePosition = 1.0
    }

    /// Writes `output.count` resampled values and returns how many input samples were consumed.
    ///
    /// - Parameter speedRatio: input samples per output sample.
    mutating func process(speedRatio: Double, input: [Float], output: inout [Float]) -> Int {
        var used = 0
        var position = subSamplePosition

        for i in 0..<output.count {
            while position >= 1.0 {
                // The caller sizes the request so this stays in range; zero-fill is belt and braces.
                buffer[index] = used < input.count ? input[used] : 0
                used += 1
                index += 1
                if index == Self.memorySize { index = 0 }
                position -= 1.0
            }

            output[i] = Self.value(buffer, at: Float(position), oldest: index)
            position += speedRatio
        }

        subSamplePosition = position
        return used
    }

    /// The interpolated value at `offset` past the third-oldest sample in the ring.
    static func value(_ inputs: [Float], at offset: Float, oldest: Int) -> Float {
        var result: Float = 0
        var index = oldest

        for k in 0..<memorySize {
            result += coefficient(inputs[index], offset: offset, k: k)
            index += 1
            if index == memorySize { index = 0 }
        }

        return result
    }

    /// The Lagrange basis polynomial for node `k`, over nodes at -2, -1, 0, 1, 2.
    private static func coefficient(_ input: Float, offset: Float, k: Int) -> Float {
        var value = input

        for m in 0..<memorySize where m != k {
            value *= (Float(m) - 2.0 - offset) / Float(m - k)
        }

        return value
    }
}

/// Sample-rate conversion for the transcription path: many channels in, one stream out.
///
/// The downmix, the anti-alias filter and the interpolation all happen in one pass, and all of the
/// state (filter memory, the interpolator's fractional position, the samples a block left over)
/// carries between calls, so a recording handed over in blocks converts exactly as the whole file
/// would have.
///
/// The output lags the input by ``LagrangeInterpolator/baseLatency`` input samples: the stream is
/// primed with two zeros, which is why a block of `n` samples yields `floor((n + 2) / ratio)`.
public struct Resampler {
    private let sourceRate: Double
    private let targetRate: Double
    private let speedRatio: Double

    /// Empty when not downsampling: there is nothing to alias, so nothing to filter.
    private var filters: [Biquad]

    /// Input samples handed to the interpolator but not yet consumed, oldest first.
    private var pending: [Float]

    private var interpolator = LagrangeInterpolator()

    public init(sourceRate: Double, targetRate: Double) {
        precondition(sourceRate > 0 && targetRate > 0, "sample rates must be positive")

        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.speedRatio = sourceRate / targetRate

        // Butterworth at half the target rate, order 4 -- NeuralNote's anti-alias filter.
        self.filters =
            targetRate < sourceRate
            ? Biquad.butterworthLowPass(
                frequency: targetRate / 2.0, sampleRate: sourceRate, order: 4)
            : []

        self.pending = [Float](repeating: 0, count: LagrangeInterpolator.baseLatency)
    }

    /// Converts one block: the channels are averaged to mono, low-passed if the rate is going down,
    /// and interpolated onto the target rate.
    ///
    /// Averaged, not summed: a downmix that can exceed the input's peak would clip a hot master, and
    /// the model is sensitive to level.
    public mutating func process(channels: [[Float]]) -> [Float] {
        guard !channels.isEmpty else { return [] }

        let count = channels.reduce(Int.max) { Swift.min($0, $1.count) }
        let scale = 1.0 / Float(channels.count)

        pending.reserveCapacity(pending.count + count)

        for i in 0..<count {
            var sample: Float = 0
            for channel in channels {
                sample += channel[i]
            }
            sample *= scale

            for f in filters.indices {
                sample = filters[f].process(sample)
            }

            pending.append(sample)
        }

        let outputCount = Int((Double(pending.count) / speedRatio).rounded(.down))
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        let used = interpolator.process(speedRatio: speedRatio, input: pending, output: &output)

        pending.removeFirst(Swift.min(used, pending.count))

        return output
    }

    /// Drops the filter and interpolator memory, for a stream that is starting over.
    public mutating func reset() {
        for f in filters.indices {
            filters[f].reset()
        }
        interpolator.reset()
        pending = [Float](repeating: 0, count: LagrangeInterpolator.baseLatency)
    }

    /// The whole signal as the 16 kHz mono the transcription model expects.
    public static func toMono16k(channels: [[Float]], sourceRate: Double) -> [Float] {
        var resampler = Resampler(sourceRate: sourceRate, targetRate: 16000)
        return resampler.process(channels: channels)
    }

    /// Each channel converted on its own, for a playback buffer that has to stay stereo.
    public static func resample(channels: [[Float]], from: Double, to: Double) -> [[Float]] {
        channels.map { channel in
            var resampler = Resampler(sourceRate: from, targetRate: to)
            return resampler.process(channels: [channel])
        }
    }
}
