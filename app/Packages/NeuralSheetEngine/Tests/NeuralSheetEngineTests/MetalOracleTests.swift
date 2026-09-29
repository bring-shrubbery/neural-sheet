// The same oracle comparisons `ModelOracleTests` and `GenerateOracleTests` make on the
// CPU, run again on the Metal backend, plus one test the CPU suites cannot make: the two
// backends fed the same prefix have to agree with each other, not merely each with the
// reference.
//
// The token fixtures come from `oracle/small-metal/` and the tensor fixtures from
// `oracle/small-cpu/`. That is not an oversight: the C++ engine's Metal and CPU dumps
// agree token for token (the two `tokens.json` files are byte-identical), so the streams
// are read from the backend's own directory as a matter of principle, while the logits
// and the conditioning are only dumped once because their tolerances are wide enough to
// cover both devices.
//
// The suite is serialised. Every test here brings up its own 209 MB of weights and 218 MB
// of KV cache in GPU-resident buffers, and there is one GPU, so running them at the same
// time buys nothing and costs a few gigabytes of wired memory.

import Foundation
import Metal
import Testing

@testable import NeuralSheetEngine

@Suite(.serialized) struct MetalOracleTests {
    /// The `small` checkpoint's prefix: 501 conditioning frames, the dataset row, one
    /// instrument row and the initial token. @see ModelOracleTests
    private static let defaultPrefill = 504

    private static let maxTokens = 2000
    private static let eosID: Int32 = 1
    private static let chunkFrames = 501

    /// Every kernel the backend dispatches, which is also every kernel the shader source
    /// is required to define.
    private static let kernelNames = [
        "layer_norm", "matvec_f16", "matmul_tiled_f16", "copy_kv", "attn_scores", "softmax_rows",
        "attn_values", "attn_decode", "gelu_erf", "add_inplace",
    ]

    /// Skips without a Metal device or the `small` checkpoint: the package never downloads a
    /// model, and a machine with no GPU must still be able to run the suite. The audio is a
    /// committed fixture and is read rather than skipped on.
    private func setUp(contextSize: Int = 2538) throws -> (model: Model, conditioning: [Float])? {
        guard let (model, frontEnd, audio) = try loadModel(contextSize: contextSize) else { return nil }
        return (model, try conditioning(frontEnd, audio, chunk: 0))
    }

    /// @see setUp
    private func loadModel(
        contextSize: Int = 2538
    ) throws -> (model: Model, frontEnd: ConditioningFrontEnd, audio: [Float])? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }

        let audio = try Fixtures.fixtureAudio()
        let model = try Model.load(url: checkpoint, useGPU: true, contextSize: contextSize)

        // The point of every test below: a silent fall back to the CPU would make them all
        // pass while testing nothing.
        #expect(model.backendName == "Metal")

        let frontEnd = try ConditioningFrontEnd(file: model.file, weights: model.weights, hparams: model.hparams)
        return (model, frontEnd, audio)
    }

    /// One chunk of the fixture, padded the way `Transcriber` pads the last one.
    private func conditioning(_ frontEnd: ConditioningFrontEnd, _ audio: [Float], chunk: Int) throws -> [Float] {
        try frontEnd.encodeAudio(Fixtures.chunk(audio, chunk))
    }

    // MARK: - The shader source

    @Test func theShaderSourceCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        // `makeLibrary` is the only check that matters: MSL is compiled at runtime here, so
        // a typo in the source is a crash at the first forward pass and not a build error.
        let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)

        for name in MetalOracleTests.kernelNames {
            #expect(library.makeFunction(name: name) != nil, "the shader source defines no '\(name)'")
        }
    }

    // MARK: - The forward pass

    @Test func prefillLogitsMatchTheOracle() throws {
        guard let (model, conditioning) = try setUp() else { return }

        // The dump is in the repository, so it is required and not skipped on: the device and
        // the checkpoint are the only things a machine is allowed to be without.
        let oracle = try Fixtures.floats("oracle/small-cpu/prefill_logits.f32")

        let logits = try model.prefill(
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])

        #expect(logits.count == model.hparams.vocabSize)
        #expect(logits.count == oracle.count)
        #expect(Compare.argmax(logits) == Compare.argmax(oracle))

        // The masked tail is -infinity in both, which would make the cosine a NaN, so the
        // comparison stops where the vocabulary the model may emit does. @see ModelOracleTests
        let sampled = model.hparams.logitMaskStart
        let cosine = Compare.cosine(Array(logits[0 ..< sampled]), Array(oracle[0 ..< sampled]))
        #expect(cosine > 0.999, "cosine \(cosine)")

        for index in sampled ..< logits.count {
            #expect(logits[index] == -.infinity, "logit \(index) is not masked")
        }

        #expect(model.nPast == MetalOracleTests.defaultPrefill)
    }

    @Test func decodeStepsMatchTheOracle() throws {
        guard let (model, conditioning) = try setUp() else { return }

        let steps = try #require(try Fixtures.json("oracle/small-metal/decode_steps.json") as? [String: [Int]])
        let fed = try #require(steps["fed"]).map(Int32.init)
        let expected = try #require(steps["argmax"]).map(Int32.init)
        let oracle = try Fixtures.floats("oracle/small-cpu/decode_logits.f32")

        _ = try model.prefill(
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])

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

            #expect(model.nPast == MetalOracleTests.defaultPrefill + step + 1)
        }
    }

    @Test func contextOverflowIsReported() throws {
        // 600 leaves 96 positions after the prefix, so the 97th decode is the first that
        // does not fit. The bound is checked before anything is encoded, so nothing is
        // dispatched and nPast stops at the context size. @see ModelOracleTests
        guard let (model, conditioning) = try setUp(contextSize: 600) else { return }

        _ = try model.prefill(
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])
        #expect(model.nPast == MetalOracleTests.defaultPrefill)

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
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])
        #expect(logits[1135] == -.infinity)
        #expect(logits[1136] == -.infinity)

        model.setForbiddenTokens([])
        #expect(!model.hasForbiddenTokens)
        model.reset()

        logits = try model.prefill(
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])
        #expect(logits[1135].isFinite)
        #expect(logits[1136].isFinite)
    }

    @Test func instrumentRowsChangeThePrefixLength() throws {
        guard let (model, conditioning) = try setUp() else { return }

        model.setInstrumentRows([10, 38])
        #expect(model.instrumentRows == [10, 38])

        _ = try model.prefill(
            conditioning: conditioning, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(model.hparams.initialTokenID)])
        #expect(model.nPast == MetalOracleTests.defaultPrefill + 1)

        model.setInstrumentRows([])
        #expect(model.instrumentRows == [InstrumentGroups.nullConditioningRow])
    }

    // MARK: - The two backends against each other

    @Test func cpuAndMetalLogitsAgree() throws {
        guard let checkpoint = Checkpoints.url(for: .small) else { return }
        guard let (metal, frontEnd, audio) = try loadModel() else { return }

        let cond = try conditioning(frontEnd, audio, chunk: 0)
        let onMetal = try metal.prefill(
            conditioning: cond, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(metal.hparams.initialTokenID)])

        let cpu = try Model.load(url: checkpoint, useGPU: false, contextSize: 2538)
        #expect(cpu.backendName == "CPU")
        let onCPU = try cpu.prefill(
            conditioning: cond, frameCount: MetalOracleTests.chunkFrames,
            tokens: [Int32(cpu.hparams.initialTokenID)])

        // Tighter than either backend's bound against the reference, because here nothing
        // rounds to F16 in between: the two differ only in the order they accumulate and in
        // the layer norm's reduction, so a cosine below this is a bug and not a device.
        let sampled = metal.hparams.logitMaskStart
        let cosine = Compare.cosine(Array(onMetal[0 ..< sampled]), Array(onCPU[0 ..< sampled]))
        #expect(cosine > 0.9999, "cosine \(cosine)")
        #expect(Compare.argmax(onMetal) == Compare.argmax(onCPU))
    }

    // MARK: - The greedy loop

    @Test func everyChunkGeneratesTheOracleTokens() throws {
        guard let (model, frontEnd, audio) = try loadModel() else { return }

        let oracle = try #require(try Fixtures.json("oracle/small-metal/tokens.json") as? [String: [[Int]]])
        let chunks = try #require(oracle["chunks"]).map { $0.map(Int32.init) }

        #expect(chunks.count == 3)

        for chunk in chunks.indices {
            let cond = try conditioning(frontEnd, audio, chunk: chunk)
            let tokens = try model.generate(
                conditioning: cond, frameCount: MetalOracleTests.chunkFrames,
                maxTokens: MetalOracleTests.maxTokens, eosID: MetalOracleTests.eosID)

            #expect(tokens.count == chunks[chunk].count, "chunk \(chunk) token count")
            #expect(tokens == chunks[chunk], "chunk \(chunk) diverges at \(firstDifference(tokens, chunks[chunk]))")
        }
    }

    @Test func bandSelectionGeneratesTheOracleTokens() throws {
        guard let (model, frontEnd, audio) = try loadModel() else { return }

        let oracle = try #require(try Fixtures.json("oracle/small-metal/tokens_band.json") as? [String: Any])
        let names = try #require(oracle["instruments"] as? [String])
        let expected = try #require(oracle["chunk0"] as? [Int]).map(Int32.init)

        let band = names.compactMap { InstrumentGroups.group(forName: $0) }
        #expect(band.count == names.count)

        model.setInstrumentRows(InstrumentGroups.conditioningRows(band))
        model.setForbiddenTokens(InstrumentGroups.forbiddenTokenIDs(band))

        let cond = try conditioning(frontEnd, audio, chunk: 0)
        let tokens = try model.generate(
            conditioning: cond, frameCount: MetalOracleTests.chunkFrames,
            maxTokens: MetalOracleTests.maxTokens, eosID: MetalOracleTests.eosID)

        #expect(tokens.count == expected.count)
        #expect(tokens == expected, "the band stream diverges at \(firstDifference(tokens, expected))")
    }

    @Test func aPromptIsReturnedFirst() throws {
        guard let (model, frontEnd, audio) = try loadModel() else { return }

        let prompt: [Int32] = [1135, 1064, 1134]
        let cond = try conditioning(frontEnd, audio, chunk: 0)
        let tokens = try model.generate(
            conditioning: cond, frameCount: MetalOracleTests.chunkFrames,
            maxTokens: MetalOracleTests.maxTokens, eosID: MetalOracleTests.eosID, prompt: prompt)

        #expect(Array(tokens.prefix(prompt.count)) == prompt)
        #expect(tokens.count > prompt.count)
        #expect(tokens.count <= MetalOracleTests.maxTokens)
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
