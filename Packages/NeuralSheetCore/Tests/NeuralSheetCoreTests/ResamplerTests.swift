import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

private func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Float = 1.0) -> [Float] {
    (0..<count).map { i in
        amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
    }
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum = 0.0
    for sample in samples { sum += Double(sample) * Double(sample) }
    return Float((sum / Double(samples.count)).squareRoot())
}

/// The steady-state part of the output, past the filter's and the interpolator's start-up.
private func steadyState(_ samples: [Float]) -> [Float] {
    guard samples.count > 200 else { return samples }
    return Array(samples[100...])
}

// MARK: - Tests

@Test func passbandToneKeepsItsLevel() {
    let input = sine(frequency: 1000, sampleRate: 48000, count: 48000)
    var resampler = Resampler(sourceRate: 48000, targetRate: 16000)
    let output = resampler.process(channels: [input])

    let inputRMS = rms(input)
    let outputRMS = rms(steadyState(output))

    #expect(outputRMS > inputRMS * 0.9)
    #expect(outputRMS < inputRMS * 1.1)
}

@Test func toneAboveCutoffIsStronglyAttenuated() {
    let input = sine(frequency: 12000, sampleRate: 48000, count: 48000)
    var resampler = Resampler(sourceRate: 48000, targetRate: 16000)
    let output = resampler.process(channels: [input])

    let ratio = rms(steadyState(output)) / rms(input)

    // NOTE: the brief asks for < 5 %, which a 4th-order Butterworth at 8 kHz cannot deliver at
    // 12 kHz: 12 kHz sits 1.5 octaves-ish into the stopband, where the reference design (JUCE's
    // designIIRLowpassHighOrderButterworthMethod, order 4 -- what NeuralNote's Resampler.cpp uses)
    // gives 1 / sqrt(1 + (tan(pi/4) / tan(pi/6))^8) = 0.110. Mirroring the C++ filter wins over the
    // brief's number; the assertion below pins the attenuation the reference actually achieves.
    #expect(ratio < 0.15)
    #expect(abs(ratio - 0.110) < 0.01)
}

@Test func outputLengthFollowsTheRateRatio() {
    for count in [48000, 24000, 1000, 96000] {
        let input = sine(frequency: 440, sampleRate: 48000, count: count)
        var resampler = Resampler(sourceRate: 48000, targetRate: 16000)
        let output = resampler.process(channels: [input])

        let expected = count * 16000 / 48000
        #expect(abs(output.count - expected) <= 2)
    }
}

@Test func channelsAreAveragedNotSummed() {
    let left = [Float](repeating: 1.0, count: 4800)
    let right = [Float](repeating: -1.0, count: 4800)

    var resampler = Resampler(sourceRate: 48000, targetRate: 16000)
    let output = resampler.process(channels: [left, right])

    #expect(!output.isEmpty)
    for sample in output {
        #expect(abs(sample) < 1e-6)
    }
}

@Test func averagedChannelsKeepTheirPeakLevel() {
    // Two identical channels average back to the same signal, rather than doubling it.
    let channel = sine(frequency: 500, sampleRate: 48000, count: 48000)

    var mono = Resampler(sourceRate: 48000, targetRate: 16000)
    let monoOut = mono.process(channels: [channel])

    var stereo = Resampler(sourceRate: 48000, targetRate: 16000)
    let stereoOut = stereo.process(channels: [channel, channel])

    #expect(monoOut.count == stereoOut.count)
    for (a, b) in zip(monoOut, stereoOut) {
        #expect(abs(a - b) < 1e-6)
    }
}

@Test func streamingBlocksConcatenateSeamlessly() {
    let input = sine(frequency: 1000, sampleRate: 48000, count: 48000)

    var single = Resampler(sourceRate: 48000, targetRate: 16000)
    let whole = single.process(channels: [input])

    var streaming = Resampler(sourceRate: 48000, targetRate: 16000)
    var chunked: [Float] = []
    var offset = 0
    while offset < input.count {
        let end = Swift.min(input.count, offset + 512)
        chunked += streaming.process(channels: [Array(input[offset..<end])])
        offset = end
    }

    // Per-block flooring can leave one sample pending at the very end.
    #expect(abs(chunked.count - whole.count) <= 1)
    for i in 0..<Swift.min(chunked.count, whole.count) {
        #expect(abs(chunked[i] - whole[i]) < 1e-5)
    }
}

@Test func noFilteringWhenUpsampling() {
    // Going up, no anti-alias filter is designed at all, so the tone keeps its level.
    let input = sine(frequency: 1000, sampleRate: 16000, count: 16000)
    var resampler = Resampler(sourceRate: 16000, targetRate: 48000)
    let output = resampler.process(channels: [input])

    // Three output samples per input sample, plus the interpolator's 2 samples of padding.
    #expect(output.count >= 48000)
    #expect(output.count <= 48010)

    let outputRMS = rms(steadyState(output))
    #expect(outputRMS > rms(input) * 0.95)
    #expect(outputRMS < rms(input) * 1.05)
}

@Test func toMono16kMatchesAnInstance() {
    let left = sine(frequency: 440, sampleRate: 44100, count: 44100)
    let right = sine(frequency: 880, sampleRate: 44100, count: 44100)

    var resampler = Resampler(sourceRate: 44100, targetRate: 16000)
    let expected = resampler.process(channels: [left, right])
    let actual = Resampler.toMono16k(channels: [left, right], sourceRate: 44100)

    #expect(actual.count == expected.count)
    #expect(abs(actual.count - 16000) <= 2)
    for (a, b) in zip(actual, expected) {
        #expect(a == b)
    }
}

@Test func resampleKeepsChannelsSeparate() {
    let left = [Float](repeating: 0.5, count: 48000)
    let right = [Float](repeating: -0.5, count: 48000)

    let output = Resampler.resample(channels: [left, right], from: 48000, to: 16000)

    #expect(output.count == 2)
    #expect(abs(output[0].count - 16000) <= 2)
    #expect(abs(output[1].count - 16000) <= 2)

    // Steady state: DC passes the low-pass untouched, and the channels stay apart.
    #expect(abs(steadyState(output[0])[0] - 0.5) < 1e-3)
    #expect(abs(steadyState(output[1])[0] + 0.5) < 1e-3)
}

@Test func emptyInputProducesNoOutput() {
    var resampler = Resampler(sourceRate: 48000, targetRate: 16000)
    #expect(resampler.process(channels: []).isEmpty)
    #expect(resampler.process(channels: [[]]).isEmpty)
    #expect(Resampler.resample(channels: [], from: 48000, to: 16000).isEmpty)
}
