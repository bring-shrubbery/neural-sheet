// Ported from `Model` in muscriptor.cpp's cpp/src/model.cpp: `load`, `reset`,
// `setInstrumentRows`, `setForbiddenTokens` and `applyLogitMask`. The forward pass proper
// lives behind `TransformerBackend`, and what the C++ kept in `Impl` -- the sequence
// position, the conditioning selection, the forbidden mask -- is kept here.

import Foundation

/// One loaded checkpoint, driven a window at a time.
///
/// Everything that is not a matrix product is here: the prefix a chunk starts with, the
/// position rows, the logit mask and the greedy loop. That is deliberate -- it is the part
/// that decides which token comes out, so it must not be written twice, once per device.
///
/// A model carries the sequence it is decoding (`nPast`), so it is stateful: call `reset()`
/// before feeding a new chunk. One call at a time; nothing here is thread-safe.
final class Model {
    let hparams: Hparams

    /// `contextSize` rows, so a position is never computed twice.
    let positions: PositionTable

    let backend: TransformerBackend

    /// Held so the front-end can be built from the same mapping the weights came out of,
    /// which is what `Transcriber` does rather than opening the checkpoint twice.
    let file: GGUFFile
    let weights: ModelWeights

    var backendName: String { backend.name }
    var contextSize: Int { backend.contextSize }

    /// Positions already in the KV cache: the length of the sequence fed since `reset()`.
    private(set) var nPast = 0

    /// The `instrument_group` rows the prefix conditions on, one row per selected group, or
    /// the single null row when nothing is selected. Never empty. @see setInstrumentRows
    private(set) var instrumentRows: [Int32] = [InstrumentGroups.nullConditioningRow]

    /// `[vocabSize]` of flags, or empty when nothing is forbidden. Empty rather than
    /// all-false so that the common case costs nothing per forward pass.
    private var forbidden: [Bool] = []

    var hasForbiddenTokens: Bool { !forbidden.isEmpty }

    /// `token_embd.weight` as F32, `[vocabSize + 1][dim]`: the initial token is the extra
    /// row past the vocabulary. @see Model+Embeddings
    let tokenEmbedding: [Float]

    /// `cond.dataset_name.weight` as F32, `[5][dim]`.
    let datasetEmbedding: [Float]

    /// `cond.instrument_group.weight` as F32, `[1001][dim]`.
    let instrumentEmbedding: [Float]

    /// The C++ `Transcriber`'s context: 501 conditioning frames, the dataset row, up to 35
    /// instrument rows, the initial token and 2000 generated tokens.
    static let defaultContextSize = 501 + 1 + 35 + 1 + 2000

    init(file: GGUFFile, hparams: Hparams, weights: ModelWeights, backend: TransformerBackend) throws {
        self.file = file
        self.hparams = hparams
        self.weights = weights
        self.backend = backend
        positions = try PositionTable(
            count: backend.contextSize, dim: hparams.dim, maxPeriod: hparams.maxPeriod)

        let tables = try Model.embeddingTables(file: file, weights: weights, hparams: hparams)
        tokenEmbedding = tables.token
        datasetEmbedding = tables.dataset
        instrumentEmbedding = tables.instrument

        reset()
    }

    /// Opens the checkpoint, reads its hyperparameters and weights and brings up a backend:
    /// Metal when `useGPU` and a device answers, the CPU otherwise.
    static func load(url: URL, useGPU: Bool, contextSize: Int = Model.defaultContextSize) throws -> Model {
        let file = try GGUFFile(url: url)
        let hparams = try Hparams(file: file)
        let weights = try ModelWeights(file: file, hparams: hparams)

        let backend: TransformerBackend

        if useGPU,
            let metal = Model.makeMetalBackend(
                file: file, hparams: hparams, weights: weights, contextSize: contextSize) {
            backend = metal
        } else {
            backend = try CPUBackend(file: file, hparams: hparams, weights: weights, contextSize: contextSize)
        }

        return try Model(file: file, hparams: hparams, weights: weights, backend: backend)
    }

    /// The GPU seam. It is a hook rather than a direct reference so that this file does not
    /// depend on Metal at all: the Metal backend replaces the body, and until it exists
    /// `load` answers the CPU whatever the caller asked for.
    static func makeMetalBackend(
        file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int
    ) -> TransformerBackend? {
        nil
    }

    /// Forgets the sequence: the next `prefill` starts at position zero again.
    func reset() {
        nPast = 0
        backend.reset()
    }

    /// The conditioning rows for the caller's instrument selection. An empty selection is
    /// the null row and not no row: the conditioner always contributes exactly one
    /// embedding, which is why this can never leave `instrumentRows` empty.
    func setInstrumentRows(_ rows: [Int32]) {
        instrumentRows = rows.isEmpty ? [InstrumentGroups.nullConditioningRow] : rows
    }

    /// Token ids that every forward pass forces to -infinity. An empty array clears the
    /// mask; an id outside the vocabulary is ignored rather than rejected, as in the C++,
    /// because the caller's table and the checkpoint's vocabulary are allowed to disagree at
    /// the edges.
    func setForbiddenTokens(_ ids: [Int32]) {
        guard !ids.isEmpty else {
            forbidden = []
            return
        }

        forbidden = [Bool](repeating: false, count: hparams.vocabSize)

        for id in ids where id >= 0 && Int(id) < hparams.vocabSize {
            forbidden[Int(id)] = true
        }
    }

    /// The reserved tail first, then the caller's forbidden ids, which is the order
    /// `_compute_logits` masks in -- and it masks on every pass, prefill included, not only
    /// inside the sampling loop.
    func applyLogitMask(_ logits: inout [Float]) {
        // `min` rather than the bare start, so a checkpoint whose mask starts past its own
        // vocabulary masks nothing instead of trapping on the range.
        for index in min(hparams.logitMaskStart, logits.count) ..< logits.count {
            logits[index] = -.infinity
        }

        for index in 0 ..< min(forbidden.count, logits.count) where forbidden[index] {
            logits[index] = -.infinity
        }
    }
}

extension Model {
    /// The forward pass over an assembled `[nNew][dim]` layer input, with the logit mask
    /// applied and the sequence advanced.
    ///
    /// The count moves only after the pass has succeeded, so a rejected window -- a context
    /// overflow, say -- leaves the model exactly where it was. @see prefill, decode
    func run(input: [Float], nNew: Int) throws -> [Float] {
        var logits = try backend.forward(input: input, nNew: nNew, nPast: nPast)
        nPast += nNew
        applyLogitMask(&logits)
        return logits
    }
}
