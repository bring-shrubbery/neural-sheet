// The conditioning front-end against the C++'s own `cond.embed` for the fixture's
// first chunk. There is no hand-computable reference for a 512-band filterbank and a
// 768-wide projection, so the oracle is the whole test, plus the one structural fact
// that is easy to get wrong and invisible in a norm: the 501st frame is masked away
// because the mask comes from the waveform length and not from the frame count.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct ConditioningOracleTests {
    /// Skips without the `small` checkpoint; the package never downloads a model, so a clean
    /// checkout must still be able to run the suite. The dump is a committed fixture and is
    /// required rather than skipped on.
    private func loadFrontEnd() throws -> (ConditioningFrontEnd, [Float])? {
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }

        let oracle = try Fixtures.floats("oracle/small-cpu/cond.f32")

        let file = try GGUFFile(url: checkpoint)
        let hparams = try Hparams(file: file)
        let weights = try ModelWeights(file: file, hparams: hparams)
        return (try ConditioningFrontEnd(file: file, weights: weights, hparams: hparams), oracle)
    }

    @Test func matchesTheReferenceEmbedding() throws {
        guard let (frontEnd, oracle) = try loadFrontEnd() else { return }

        let audio = try Fixtures.fixtureAudio()
        let embedding = try frontEnd.encodeAudio(Array(audio[0 ..< 80_000]))

        #expect(embedding.count == 501 * frontEnd.hparams.dim)
        #expect(oracle.count == embedding.count)

        let scale = Compare.scale(oracle)
        let worst = Compare.maxAbsDifference(embedding, oracle)
        #expect(worst < 1e-3 * scale, "worst deviation \(worst) against scale \(scale)")

        let cosine = Compare.cosine(embedding, oracle)
        #expect(cosine > 0.99999, "cosine \(cosine)")
    }

    @Test func theLastFrameIsMaskedAndTheRestAreNot() throws {
        guard let (frontEnd, _) = try loadFrontEnd() else { return }

        let dim = frontEnd.hparams.dim
        let audio = try Fixtures.fixtureAudio()
        let embedding = try frontEnd.encodeAudio(Array(audio[0 ..< 80_000]))

        let last = Array(embedding[(500 * dim) ..< (501 * dim)])
        #expect(Compare.scale(last) == 0, "frame 500 is not zeroed")

        for frame in 0 ..< 500 {
            let row = Array(embedding[(frame * dim) ..< ((frame + 1) * dim)])
            #expect(Compare.scale(row) > 0, "frame \(frame) is unexpectedly zero")
        }
    }
}
