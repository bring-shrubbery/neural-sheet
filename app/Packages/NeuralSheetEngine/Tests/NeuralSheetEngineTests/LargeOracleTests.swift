// The port at the biggest size the app offers, and the acceptance test for the kernels the
// performance pass rewrote. `small` is dim 768 over 14 layers and `medium` is 1024 over 24;
// `large` is 1536 over 48 with 24 heads, which is where a widened matvec's row blocking, a
// fused attention kernel's threadgroup budget and a GEMM tile that only happens to divide
// the smaller shapes stop agreeing with the reference. The token streams are the test: they
// diverge within a handful of tokens when a kernel is wrong.
//
// Both backends, against their own oracle directory, with the same two comparisons
// MediumOracleTests makes: every chunk's unconditional stream, and the default variant's
// notes end to end.
//
// Every test skips without the large checkpoint -- the package never downloads a model --
// but not without its dumps, which are in the repository. The suite is serialised and
// tagged `.slow`: each test brings up 2.7 GB of F16 weights and decodes fourteen hundred
// tokens, so this is minutes rather than seconds and two of them at once only competes for
// memory bandwidth.

import Foundation
import Metal
import Testing

@testable import NeuralSheetEngine

@Suite(.serialized, .tags(.slow)) struct LargeOracleTests {
    private static let eosID: Int32 = 1
    private static let chunkFrames = 501

    /// A large model on one backend plus the fixture audio, or nil when the machine has no
    /// large checkpoint (or, on Metal, no device). The audio is a committed fixture and is
    /// read rather than skipped on.
    private func loadModel(
        useGPU: Bool
    ) throws -> (model: Model, frontEnd: ConditioningFrontEnd, audio: [Float])? {
        if useGPU, MTLCreateSystemDefaultDevice() == nil { return nil }
        guard let checkpoint = Checkpoints.url(for: .large) else { return nil }

        let audio = try Fixtures.fixtureAudio()

        let model = try Model.load(
            url: checkpoint, useGPU: useGPU, contextSize: Transcriber.requiredContextSize)

        // A silent fall back to the CPU would make the Metal half of this suite pass while
        // testing the CPU twice.
        #expect(model.backendName == (useGPU ? "Metal" : "CPU"))

        let frontEnd = try ConditioningFrontEnd(
            file: model.file, weights: model.weights, hparams: model.hparams)
        return (model, frontEnd, audio)
    }

    /// A large transcriber on one backend plus the fixture audio. @see loadModel
    private func loadTranscriber(useGPU: Bool) throws -> (transcriber: Transcriber, audio: [Float])? {
        if useGPU, MTLCreateSystemDefaultDevice() == nil { return nil }
        guard let checkpoint = Checkpoints.url(for: .large) else { return nil }

        let audio = try Fixtures.fixtureAudio()
        let transcriber = try Transcriber(url: checkpoint, options: LoadOptions(useGPU: useGPU))
        #expect(transcriber.backendName == (useGPU ? "Metal" : "CPU"))
        return (transcriber, audio)
    }

    /// Every chunk's greedy stream, unconditional, against the oracle's. `directory` is the
    /// dump for the backend under test: the two agree token for token on this fixture, and
    /// reading each backend's own dump is what would show it if they ever stopped.
    private func expectOracleTokens(useGPU: Bool, directory: String) throws {
        guard let (model, frontEnd, audio) = try loadModel(useGPU: useGPU) else { return }

        // The dump is in the repository, so it is required and not skipped on: the
        // checkpoint above is the only thing a machine is allowed to be without.
        let oracle = try #require(try Fixtures.json("oracle/\(directory)/tokens.json") as? [String: [[Int]]])
        let chunks = try #require(oracle["chunks"]).map { $0.map(Int32.init) }

        #expect(chunks.count == 3)

        for chunk in chunks.indices {
            let cond = try frontEnd.encodeAudio(Fixtures.chunk(audio, chunk))
            let tokens = try model.generate(
                conditioning: cond, frameCount: LargeOracleTests.chunkFrames,
                maxTokens: Transcriber.maxTokensPerChunk, eosID: LargeOracleTests.eosID)

            #expect(tokens.count == chunks[chunk].count, "\(directory) chunk \(chunk) token count")
            #expect(
                tokens == chunks[chunk],
                "\(directory) chunk \(chunk) diverges at \(firstDifference(tokens, chunks[chunk]))")
        }
    }

    // MARK: - The checkpoint

    @Test func theInstalledCheckpointIsTheOneTheOracleDumped() throws {
        // Skips without the checkpoint, like everything else here. This is the only test in
        // the suite that costs nothing, and it is what makes a token mismatch below readable:
        // a different large file would fail here first.
        guard let url = Checkpoints.url(for: .large) else { return }

        let dump = try #require(try Fixtures.json("oracle/large-cpu/hparams.json") as? [String: Any])

        let hparams = try Hparams(file: GGUFFile(url: url))

        #expect(hparams.dim == dump["dim"] as? Int)
        #expect(hparams.nHead == dump["n_head"] as? Int)
        #expect(hparams.headDim == dump["head_dim"] as? Int)
        #expect(hparams.nLayer == dump["n_layer"] as? Int)
        #expect(hparams.ffnDim == dump["ffn_dim"] as? Int)
        #expect(hparams.vocabSize == dump["vocab_size"] as? Int)
        #expect(hparams.initialTokenID == dump["initial_token_id"] as? Int)
        #expect(hparams.logitMaskStart == dump["logit_mask_start"] as? Int)
        #expect(dump["checkpoint"] as? String == CheckpointSize.large.fileName)
    }

    // MARK: - The greedy loop

    @Test func everyChunkGeneratesTheOracleTokensOnTheCPU() throws {
        try expectOracleTokens(useGPU: false, directory: "large-cpu")
    }

    @Test func everyChunkGeneratesTheOracleTokensOnMetal() throws {
        try expectOracleTokens(useGPU: true, directory: "large-metal")
    }

    // MARK: - The whole engine

    @Test func preludeVariantMatchesOnTheCPU() throws {
        guard let (transcriber, audio) = try loadTranscriber(useGPU: false) else { return }
        try OracleNotes.expectVariant(.prelude, through: transcriber, samples: audio, from: "large-cpu")
    }

    @Test func preludeVariantMatchesOnMetal() throws {
        guard let (transcriber, audio) = try loadTranscriber(useGPU: true) else { return }
        try OracleNotes.expectVariant(.prelude, through: transcriber, samples: audio, from: "large-metal")
    }

    /// The index the two streams first disagree at, for a failure message that names the
    /// step to bisect from rather than printing a thousand tokens.
    private func firstDifference(_ a: [Int32], _ b: [Int32]) -> String {
        for index in 0 ..< min(a.count, b.count) where a[index] != b[index] {
            return "step \(index): \(a[index]) vs \(b[index])"
        }

        return "step \(min(a.count, b.count)): lengths \(a.count) and \(b.count)"
    }
}
