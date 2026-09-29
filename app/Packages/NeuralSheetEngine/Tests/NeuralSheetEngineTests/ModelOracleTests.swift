// The model's own forward pass against the C++ engine's, one step at a time: the prefill
// logits, then the first sixteen decode steps, then the three behaviours that change the
// shape of a pass rather than its numbers (the context bound, the forbidden mask and the
// conditioning rows).
//
// The logits cannot be compared element for element. ggml's CPU backend rounds its
// activations to F16 before an F16 matmul and this port keeps them in F32, so every
// number differs in the third or fourth decimal by the end of fourteen layers. What has
// to match is the decision taken from them, so the assertions are the argmax and the
// cosine, and a step whose top two logits are within 0.05 of each other in the reference
// is allowed to pick the other one -- there the reference's own rounding decides the
// token, not the model.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct ModelOracleTests {
    /// The `small` checkpoint's prefix: 501 conditioning frames, the dataset row, one
    /// instrument row and the initial token.
    private static let defaultPrefill = 504

    /// Skips without the `small` checkpoint or the oracle dump; the package never
    /// downloads a model, so a clean checkout must still be able to run the suite.
    private func setUp(contextSize: Int = 2538) throws -> (model: Model, conditioning: [Float])? {
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }
        guard let audio = try? Fixtures.fixtureAudio() else { return nil }

        let model = try Model.load(url: checkpoint, useGPU: false, contextSize: contextSize)
        let frontEnd = try ConditioningFrontEnd(file: model.file, weights: model.weights, hparams: model.hparams)
        return (model, try frontEnd.encodeAudio(Array(audio[0 ..< 80_000])))
    }

    @Test func prefillLogitsMatchTheOracle() throws {
        guard let oracle = try? Fixtures.floats("oracle/small-cpu/prefill_logits.f32") else { return }
        guard let (model, conditioning) = try setUp() else { return }

        let logits = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])

        #expect(logits.count == model.hparams.vocabSize)
        #expect(logits.count == oracle.count)
        #expect(Compare.argmax(logits) == Compare.argmax(oracle))

        // The masked tail is -infinity in both, which would make the cosine a NaN, so the
        // comparison stops where the vocabulary the model may emit does. In this checkpoint
        // the mask starts at the end of the vocabulary and the tail is empty; the loop below
        // is what would catch a checkpoint where it does not.
        let sampled = model.hparams.logitMaskStart
        let cosine = Compare.cosine(Array(logits[0 ..< sampled]), Array(oracle[0 ..< sampled]))
        #expect(cosine > 0.999, "cosine \(cosine)")

        for index in sampled ..< logits.count {
            #expect(logits[index] == -.infinity, "logit \(index) is not masked")
        }

        #expect(model.nPast == ModelOracleTests.defaultPrefill)
    }

    @Test func decodeStepsMatchTheOracle() throws {
        guard let steps = try? Fixtures.json("oracle/small-cpu/decode_steps.json") as? [String: [Int]],
            let fed = steps["fed"]?.map(Int32.init), let expected = steps["argmax"]?.map(Int32.init),
            let oracle = try? Fixtures.floats("oracle/small-cpu/decode_logits.f32")
        else { return }
        guard let (model, conditioning) = try setUp() else { return }

        _ = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])

        let vocabSize = model.hparams.vocabSize
        #expect(oracle.count == fed.count * vocabSize)

        for step in 0 ..< fed.count {
            let logits = try model.decode(token: fed[step])
            let reference = Array(oracle[(step * vocabSize) ..< ((step + 1) * vocabSize)])

            let cosine = Compare.cosine(logits, reference)
            #expect(cosine > 0.999, "step \(step) cosine \(cosine)")

            // A margin this small means the reference's own F16 rounding chose between two
            // tokens it could barely tell apart, so either answer is faithful.
            let margin = Compare.topTwoMargin(reference)
            let picked = Int32(Compare.argmax(logits))
            #expect(
                picked == expected[step] || margin < 0.05,
                "step \(step) picked \(picked), the oracle \(expected[step]), margin \(margin)")

            #expect(model.nPast == ModelOracleTests.defaultPrefill + step + 1)
        }
    }

    @Test func contextOverflowIsReported() throws {
        // 600 leaves 96 positions after the prefix, so the 97th decode is the first that
        // does not fit. The bound is checked before the pass runs, so nPast stops at the
        // context size rather than running past the end of the cache.
        guard let (model, conditioning) = try setUp(contextSize: 600) else { return }

        _ = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])
        #expect(model.nPast == ModelOracleTests.defaultPrefill)

        for _ in 0 ..< 96 {
            _ = try model.decode(token: 1134)
        }

        #expect(model.nPast == 600)
        #expect(throws: TranscriberError.contextOverflow) { try model.decode(token: 1134) }
        #expect(model.nPast == 600)
    }

    @Test func forbiddenTokensMaskTheLogits() throws {
        guard let (model, conditioning) = try setUp() else { return }

        model.setForbiddenTokens([1135, 1136])
        #expect(model.hasForbiddenTokens)

        var logits = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])
        #expect(logits[1135] == -.infinity)
        #expect(logits[1136] == -.infinity)

        model.setForbiddenTokens([])
        #expect(!model.hasForbiddenTokens)
        model.reset()

        logits = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])
        #expect(logits[1135].isFinite)
        #expect(logits[1136].isFinite)
    }

    @Test func instrumentRowsChangeThePrefixLength() throws {
        guard let (model, conditioning) = try setUp() else { return }

        model.setInstrumentRows([10, 38])
        #expect(model.instrumentRows == [10, 38])

        _ = try model.prefill(
            conditioning: conditioning, frameCount: 501, tokens: [Int32(model.hparams.initialTokenID)])
        #expect(model.nPast == ModelOracleTests.defaultPrefill + 1)

        // An empty selection is the null row, not no row at all: the conditioner always
        // contributes exactly one embedding when nothing is selected.
        model.setInstrumentRows([])
        #expect(model.instrumentRows == [InstrumentGroups.nullConditioningRow])
    }
}
