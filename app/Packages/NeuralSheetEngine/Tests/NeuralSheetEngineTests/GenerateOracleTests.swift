// The whole greedy loop against the C++ engine's, at the level the transcription actually
// depends on: the token streams. Nothing below this is compared -- the logits drift (see
// ModelOracleTests) -- but a drift that changed a token would change a note, so these
// streams must be identical, for all three chunks of the fixture and for an instrument
// selection that lengthens the prefix and masks most of the vocabulary away.
//
// This is the slowest suite in the package: three chunks of a few hundred tokens each,
// every token a pass over all of the small checkpoint's weights.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct GenerateOracleTests {
    /// The `generate` arguments the oracle used: `Transcriber`'s per-chunk budget and the
    /// vocabulary's end-of-sequence id.
    private static let maxTokens = 2000
    private static let eosID: Int32 = 1
    private static let chunkFrames = 501

    /// Skips without the `small` checkpoint; the package never downloads a model, so a
    /// clean checkout must still be able to run the suite.
    private func setUp() throws -> (model: Model, frontEnd: ConditioningFrontEnd, audio: [Float])? {
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }
        guard let audio = try? Fixtures.fixtureAudio() else { return nil }

        let model = try Model.load(url: checkpoint, useGPU: false, contextSize: 2538)
        let frontEnd = try ConditioningFrontEnd(file: model.file, weights: model.weights, hparams: model.hparams)
        return (model, frontEnd, audio)
    }

    /// One chunk of the fixture, padded the way `Transcriber` pads the last one.
    private func conditioning(_ frontEnd: ConditioningFrontEnd, _ audio: [Float], chunk: Int) throws -> [Float] {
        try frontEnd.encodeAudio(Fixtures.chunk(audio, chunk))
    }

    @Test func everyChunkGeneratesTheOracleTokens() throws {
        guard let oracle = try? Fixtures.json("oracle/small-cpu/tokens.json") as? [String: [[Int]]],
            let chunks = oracle["chunks"]?.map({ $0.map(Int32.init) })
        else { return }
        guard let (model, frontEnd, audio) = try setUp() else { return }

        #expect(chunks.count == 3)

        for chunk in chunks.indices {
            let cond = try conditioning(frontEnd, audio, chunk: chunk)
            let tokens = try model.generate(
                conditioning: cond, frameCount: GenerateOracleTests.chunkFrames,
                maxTokens: GenerateOracleTests.maxTokens, eosID: GenerateOracleTests.eosID)

            #expect(tokens.count == chunks[chunk].count, "chunk \(chunk) token count")
            #expect(tokens == chunks[chunk], "chunk \(chunk) diverges at \(firstDifference(tokens, chunks[chunk]))")
        }
    }

    @Test func bandSelectionGeneratesTheOracleTokens() throws {
        guard let oracle = try? Fixtures.json("oracle/small-cpu/tokens_band.json") as? [String: Any],
            let names = oracle["instruments"] as? [String],
            let expected = (oracle["chunk0"] as? [Int])?.map(Int32.init)
        else { return }
        guard let (model, frontEnd, audio) = try setUp() else { return }

        let band = names.compactMap { InstrumentGroups.group(forName: $0) }
        #expect(band.count == names.count)

        model.setInstrumentRows(InstrumentGroups.conditioningRows(band))
        model.setForbiddenTokens(InstrumentGroups.forbiddenTokenIDs(band))

        let cond = try conditioning(frontEnd, audio, chunk: 0)
        let tokens = try model.generate(
            conditioning: cond, frameCount: GenerateOracleTests.chunkFrames,
            maxTokens: GenerateOracleTests.maxTokens, eosID: GenerateOracleTests.eosID)

        #expect(tokens.count == expected.count)
        #expect(tokens == expected, "the band stream diverges at \(firstDifference(tokens, expected))")
    }

    @Test func aPromptIsReturnedFirst() throws {
        guard let (model, frontEnd, audio) = try setUp() else { return }

        // A prompt is teacher forcing, not sampling: it goes into the prefill and comes back
        // at the head of the answer, because the decode state machine downstream has to see
        // it to leave the tie prologue.
        let prompt: [Int32] = [1135, 1064, 1134]
        let cond = try conditioning(frontEnd, audio, chunk: 0)
        let tokens = try model.generate(
            conditioning: cond, frameCount: GenerateOracleTests.chunkFrames,
            maxTokens: GenerateOracleTests.maxTokens, eosID: GenerateOracleTests.eosID, prompt: prompt)

        #expect(Array(tokens.prefix(prompt.count)) == prompt)
        #expect(tokens.count > prompt.count)
        #expect(tokens.count <= GenerateOracleTests.maxTokens)
    }

    /// The index the two streams first disagree at, for a failure message that names the
    /// step to bisect from rather than printing hundreds of tokens.
    private func firstDifference(_ a: [Int32], _ b: [Int32]) -> String {
        for index in 0 ..< min(a.count, b.count) where a[index] != b[index] {
            return "step \(index): \(a[index]) vs \(b[index])"
        }

        return "step \(min(a.count, b.count)): lengths \(a.count) and \(b.count)"
    }
}
