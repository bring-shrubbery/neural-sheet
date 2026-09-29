// The STFT is where vDSP's conventions differ most from the reference's: pffft packs
// DC and Nyquist into one complex slot, vDSP packs them into `real[0]` and `imag[0]`
// and scales everything by two. None of that is checked by a shape assertion, so it
// is pinned here three ways over: against a naive DFT in `Double`, against two signals
// whose spectrum is known by hand, and against the C++'s own dump.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// A linear congruential generator, so the random signal below is the same on every
/// machine and every run: a tolerance failure has to be reproducible to be debuggable.
private struct FixedRandom {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D

    /// Uniform in [-1, 1), from the top 24 bits, which are the ones an LCG's low-order
    /// bits do not spoil.
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 40) / Float(1 << 24)
        return unit * 2 - 1
    }
}

/// The reference transform, written from `Stft::magnitudes` rather than from the Swift:
/// the same reflect padding and windowing, then an O(N²) DFT in `Double`.
private func referenceMagnitudes(_ samples: [Float], nFFT: Int, hopLength: Int, window: [Float]) -> [Float] {
    let pad = nFFT / 2
    let count = samples.count
    var padded = [Double](repeating: 0, count: count + 2 * pad)

    for i in 0 ..< count {
        padded[pad + i] = Double(samples[i])
    }

    for i in 0 ..< pad {
        padded[i] = Double(samples[pad - i])
        padded[pad + count + i] = Double(samples[count - 2 - i])
    }

    let frames = 1 + count / hopLength
    let bins = nFFT / 2 + 1
    var out = [Float](repeating: 0, count: frames * bins)

    for frame in 0 ..< frames {
        let start = frame * hopLength
        let windowed = (0 ..< nFFT).map { padded[start + $0] * Double(window[$0]) }

        for k in 0 ..< bins {
            var re = 0.0
            var im = 0.0

            for n in 0 ..< nFFT {
                let angle = -2.0 * Double.pi * Double(k) * Double(n) / Double(nFFT)
                re += windowed[n] * cos(angle)
                im += windowed[n] * sin(angle)
            }

            out[frame * bins + k] = Float((re * re + im * im).squareRoot())
        }
    }

    return out
}

@Suite struct STFTTests {
    private static func rectangular(_ nFFT: Int) -> [Float] { [Float](repeating: 1, count: nFFT) }

    @Test func frameCountFollowsTheCentrePaddedFormula() throws {
        let stft = try STFT(nFFT: 2048, hopLength: 160, window: STFTTests.rectangular(2048))
        #expect(stft.nFreq == 1025)
        #expect(stft.frameCount(sampleCount: 80_000) == 501)
        #expect(stft.frameCount(sampleCount: 0) == 1)
        #expect(stft.frameCount(sampleCount: -5) == 0)
    }

    @Test func matchesANaiveDoublePrecisionDFT() throws {
        let nFFT = 64
        let hop = 16
        let window = (0 ..< nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT))) }
        var random = FixedRandom()
        let samples = (0 ..< 300).map { _ in random.next() }

        let stft = try STFT(nFFT: nFFT, hopLength: hop, window: window)
        let measured = try stft.magnitudes(samples)
        let reference = referenceMagnitudes(samples, nFFT: nFFT, hopLength: hop, window: window)

        #expect(measured.count == reference.count)
        #expect(measured.count == stft.frameCount(sampleCount: 300) * stft.nFreq)

        let worst = Compare.maxAbsDifference(measured, reference)
        #expect(worst < 1e-4 * Compare.scale(reference), "worst deviation \(worst)")
    }

    @Test func reflectPaddingExcludesTheEdgeSample() throws {
        // The smallest size the transform accepts is 32, so the first frame of a ramp
        // covers x[16], x[15] … x[1], x[0], x[1] … x[15], and with a rectangular window
        // its DC bin is that sum: (16 + 15 + … + 1) + (0 + 1 + … + 15) = 136 + 120 = 256.
        // A padding that kept the edge sample would start at x[15] and give 240.
        let samples = (0 ..< 100).map { Float($0) }
        let stft = try STFT(nFFT: 32, hopLength: 16, window: STFTTests.rectangular(32))
        let magnitudes = try stft.magnitudes(samples)

        #expect(abs(magnitudes[0] - 256) < 1e-3, "first frame's DC is \(magnitudes[0])")
    }

    @Test func dcBinHoldsAConstantSignal() throws {
        let stft = try STFT(nFFT: 32, hopLength: 16, window: STFTTests.rectangular(32))
        let magnitudes = try stft.magnitudes([Float](repeating: 1, count: 64))
        let frames = stft.frameCount(sampleCount: 64)
        #expect(frames == 5)
        #expect(magnitudes.count == frames * 17)

        for frame in 0 ..< frames {
            let row = Array(magnitudes[(frame * 17) ..< ((frame + 1) * 17)])
            #expect(abs(row[0] - 32) < 1e-4, "frame \(frame) DC \(row[0])")

            for bin in 1 ..< 17 {
                #expect(abs(row[bin]) < 1e-4, "frame \(frame) bin \(bin) is \(row[bin])")
            }
        }
    }

    @Test func nyquistBinHoldsAnAlternatingSignal() throws {
        // The pad is even, so the reflection keeps the alternation going and every
        // frame is [1, -1, 1, -1, …]: all the energy sits in bin N/2, which is the one
        // vDSP hides in `imag[0]`.
        let stft = try STFT(nFFT: 32, hopLength: 16, window: STFTTests.rectangular(32))
        let magnitudes = try stft.magnitudes((0 ..< 64).map { $0 % 2 == 0 ? Float(1) : Float(-1) })
        let frames = stft.frameCount(sampleCount: 64)

        for frame in 0 ..< frames {
            let row = Array(magnitudes[(frame * 17) ..< ((frame + 1) * 17)])
            #expect(abs(row[16] - 32) < 1e-4, "frame \(frame) Nyquist \(row[16])")

            for bin in 0 ..< 17 where bin != 16 {
                #expect(abs(row[bin]) < 1e-4, "frame \(frame) bin \(bin) is \(row[bin])")
            }
        }
    }

    @Test func tooFewSamplesToReflectPadThrows() throws {
        // n_fft / 2 + 1 = 17 is the point below which the reflection has nothing left.
        let stft = try STFT(nFFT: 32, hopLength: 16, window: STFTTests.rectangular(32))
        let error = #expect(throws: TranscriberError.self) {
            try stft.magnitudes([Float](repeating: 1, count: 16))
        }

        if case .internalError = error {} else {
            Issue.record("expected .internalError, got \(String(describing: error))")
        }
    }

    @Test func aWindowOfTheWrongLengthThrows() {
        let error = #expect(throws: TranscriberError.self) {
            try STFT(nFFT: 64, hopLength: 16, window: STFTTests.rectangular(63))
        }

        if case .internalError = error {} else {
            Issue.record("expected .internalError, got \(String(describing: error))")
        }
    }

    @Test func aSizeVDSPCannotTransformThrows() {
        for (nFFT, hop) in [(48, 16), (16, 8), (0, 8), (64, 0)] {
            let error = #expect(throws: TranscriberError.self) {
                try STFT(nFFT: nFFT, hopLength: hop, window: [Float](repeating: 1, count: max(nFFT, 0)))
            }

            if case .internalError = error {} else {
                Issue.record("expected .internalError for n_fft \(nFFT) hop \(hop), got \(String(describing: error))")
            }
        }
    }
}

@Suite struct STFTOracleTests {
    /// The C++'s own magnitudes for the first eight frames of the fixture's first
    /// chunk. Skips without the oracle dump or without the `small` checkpoint, whose
    /// `cond.stft_window` is the window the reference applied.
    @Test func matchesTheReferenceDump() throws {
        guard let oracle = try? Fixtures.floats("oracle/small-cpu/stft.f32") else { return }
        guard let checkpoint = Checkpoints.url(for: .small) else { return }

        let file = try GGUFFile(url: checkpoint)
        let hparams = try Hparams(file: file)
        let weights = try ModelWeights(file: file, hparams: hparams)
        let window = try file.floats(of: weights.stftWindow)
        #expect(window.count == hparams.nFFT)

        let stft = try STFT(nFFT: hparams.nFFT, hopLength: hparams.hopLength, window: window)
        let audio = try Fixtures.fixtureAudio()
        #expect(audio.count >= 80_000)

        let magnitudes = try stft.magnitudes(Array(audio[0 ..< 80_000]))
        #expect(magnitudes.count == 501 * hparams.nFreq)

        let frames = oracle.count / hparams.nFreq
        #expect(frames == 8)

        let measured = Array(magnitudes[0 ..< oracle.count])
        let worst = Compare.maxAbsDifference(measured, oracle)
        #expect(worst < 1e-4 * Compare.scale(oracle), "worst deviation \(worst) against scale \(Compare.scale(oracle))")
    }
}
