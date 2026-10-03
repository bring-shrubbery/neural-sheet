// The port at the size a user actually transcribes with. Everything else in the package is
// checked against the `small` checkpoint, where dim is 768 and there are 14 layers; medium
// is 1024 over 24 layers, which is where a kernel that indexes a tile or a head by a
// hard-coded extent, or accumulates in a width that only happens to be enough, stops
// agreeing with the reference. The token streams are the test: they diverge within a
// handful of tokens when the graph is wrong.
//
// Both backends, against their own oracle directory. Two comparisons per backend, the ones
// the plan's ladder names: every chunk's unconditional stream, and the default variant's
// notes end to end.
//
// Every test skips without the medium checkpoint -- the package never downloads a model --
// but not without its dumps, which are in the repository. The suite is serialised and tagged `.slow`: each test brings up 614 MB
// of F16 weights and decodes a thousand-odd tokens, so this is minutes rather than seconds
// and two of them at once only competes for memory bandwidth.

import Foundation
import Metal
import Testing

@testable import NeuralSheetEngine

@Suite(.serialized, .tags(.slow)) struct MediumOracleTests {
    private static let eosID: Int32 = 1
    private static let chunkFrames = 501

    /// A medium model on one backend plus the fixture audio, or nil when the machine has no
    /// medium checkpoint (or, on Metal, no device). The audio is a committed fixture and is
    /// read rather than skipped on.
    private func loadModel(
        useGPU: Bool
    ) throws -> (model: Model, frontEnd: ConditioningFrontEnd, audio: [Float])? {
        if useGPU, MTLCreateSystemDefaultDevice() == nil { return nil }
        guard let checkpoint = Checkpoints.url(for: .medium) else { return nil }

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

    /// A medium transcriber on one backend plus the fixture audio. @see loadModel
    private func loadTranscriber(useGPU: Bool) throws -> (transcriber: Transcriber, audio: [Float])? {
        if useGPU, MTLCreateSystemDefaultDevice() == nil { return nil }
        guard let checkpoint = Checkpoints.url(for: .medium) else { return nil }

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
            let (tokens, _) = try model.generate(
                conditioning: cond, frameCount: MediumOracleTests.chunkFrames,
                maxTokens: Transcriber.maxTokensPerChunk, eosID: MediumOracleTests.eosID)

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
        // a different medium file would fail here first.
        guard let url = Checkpoints.url(for: .medium) else { return }

        let dump = try #require(try Fixtures.json("oracle/medium-cpu/hparams.json") as? [String: Any])

        let hparams = try Hparams(file: GGUFFile(url: url))

        #expect(hparams.dim == dump["dim"] as? Int)
        #expect(hparams.nHead == dump["n_head"] as? Int)
        #expect(hparams.headDim == dump["head_dim"] as? Int)
        #expect(hparams.nLayer == dump["n_layer"] as? Int)
        #expect(hparams.ffnDim == dump["ffn_dim"] as? Int)
        #expect(hparams.vocabSize == dump["vocab_size"] as? Int)
        #expect(hparams.initialTokenID == dump["initial_token_id"] as? Int)
        #expect(hparams.logitMaskStart == dump["logit_mask_start"] as? Int)
        #expect(dump["checkpoint"] as? String == CheckpointSize.medium.fileName)
    }

    // MARK: - The greedy loop

    @Test func everyChunkGeneratesTheOracleTokensOnTheCPU() throws {
        try expectOracleTokens(useGPU: false, directory: "medium-cpu")
    }

    @Test func everyChunkGeneratesTheOracleTokensOnMetal() throws {
        try expectOracleTokens(useGPU: true, directory: "medium-metal")
    }

    // MARK: - The whole engine

    @Test func preludeVariantMatchesOnTheCPU() throws {
        guard let (transcriber, audio) = try loadTranscriber(useGPU: false) else { return }
        try OracleNotes.expectVariant(.prelude, through: transcriber, samples: audio, from: "medium-cpu")
    }

    @Test func preludeVariantMatchesOnMetal() throws {
        guard let (transcriber, audio) = try loadTranscriber(useGPU: true) else { return }
        try OracleNotes.expectVariant(.prelude, through: transcriber, samples: audio, from: "medium-metal")
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
