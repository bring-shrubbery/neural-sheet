// The `ggml_get_rows` calls of `buildEvalGraph` in muscriptor.cpp's cpp/src/model.cpp,
// and the tensor reads of `Model::load` that feed them.
//
// The C++ leaves the three embedding tables in the backend buffer and gathers rows there,
// which on the GPU means a kernel and a round trip for three rows of 768 floats. Here they
// are converted to F32 once at load -- 8 MB for the small checkpoint -- and the prefix is
// gathered on the CPU, which is where it has to be assembled anyway: the conditioning
// frames in front of it come from the CPU front-end.

import Accelerate

extension Model {
    /// The three tables as F32, checked against the hyperparameters.
    ///
    /// The token embedding has one row past the vocabulary, which is where the initial token
    /// lives; the other two are class conditioners whose row count is the checkpoint's
    /// business, so they are only required to be a whole number of rows wide enough for the
    /// null row every selection falls back to.
    static func embeddingTables(
        file: GGUFFile, weights: ModelWeights, hparams: Hparams
    ) throws -> (token: [Float], dataset: [Float], instrument: [Float]) {
        let dim = hparams.dim
        let token = try file.floats(of: weights.tokenEmbd)

        guard token.count == (hparams.vocabSize + 1) * dim else {
            throw TranscriberError.invalidCheckpoint(
                "token_embd.weight is \(token.count) values, expected \((hparams.vocabSize + 1) * dim)")
        }

        let dataset = try Model.conditioner(file.floats(of: weights.datasetName), dim: dim, name: "cond.dataset_name")
        let instrument = try Model.conditioner(
            file.floats(of: weights.instrumentGroup), dim: dim, name: "cond.instrument_group")
        return (token, dataset, instrument)
    }

    private static func conditioner(_ values: [Float], dim: Int, name: String) throws -> [Float] {
        let rows = values.count / dim

        guard values.count % dim == 0, rows > Int(InstrumentGroups.nullConditioningRow) else {
            throw TranscriberError.invalidCheckpoint(
                "\(name).weight is \(values.count) values, not a whole number of \(dim)-wide rows past the null row")
        }

        return values
    }

    /// The embedding rows for `tokens`, `[tokens.count][dim]`.
    ///
    /// Every id the engine feeds is non-negative -- the initial token, a forced prologue
    /// token or an argmax -- so `ScaledEmbedding`'s negative `zero_idx` path, which the
    /// reference notes can never be reached here, is not ported.
    func embed(tokens: [Int32]) throws -> [Float] {
        try gather(tokenEmbedding, rows: tokens, name: "token_embd.weight")
    }

    /// The prefix's dataset row, which is always the unconditional one: the C++ writes
    /// `NULL_CONDITIONING_ROW` into `dataset_idx` and never anything else.
    func embedDatasetRow() throws -> [Float] {
        try gather(datasetEmbedding, rows: [InstrumentGroups.nullConditioningRow], name: "cond.dataset_name.weight")
    }

    /// One row per selected instrument group, in the caller's order.
    func embedInstrumentRows() throws -> [Float] {
        try gather(instrumentEmbedding, rows: instrumentRows, name: "cond.instrument_group.weight")
    }

    /// Copies the named rows out of a `[rowCount][dim]` table.
    ///
    /// A row index outside the table is `.internalError` and not a precondition: the
    /// instrument rows and a teacher-forced prompt both come from a caller, and a wrong one
    /// would otherwise read whatever follows the table.
    private func gather(_ table: [Float], rows: [Int32], name: String) throws -> [Float] {
        let dim = hparams.dim
        let rowCount = table.count / dim
        var out = [Float](repeating: 0, count: rows.count * dim)

        try out.withUnsafeMutableBufferPointer { destination in
            try table.withUnsafeBufferPointer { source in
                for (index, row) in rows.enumerated() {
                    guard row >= 0, Int(row) < rowCount else {
                        throw TranscriberError.internalError("\(name) has no row \(row) of \(rowCount)")
                    }

                    (destination.baseAddress! + index * dim)
                        .update(from: source.baseAddress! + Int(row) * dim, count: dim)
                }
            }
        }

        return out
    }

    /// Adds the position rows for `nPast ..< nPast + nNew` to an assembled layer input, in
    /// place.
    ///
    /// The positions are added to every row of the prefix, the conditioning frames included:
    /// the frames are a sequence like any other as far as the transformer is concerned.
    func addPositions(to input: inout [Float], nNew: Int) {
        let dim = hparams.dim
        let first = nPast * dim
        precondition(
            nPast >= 0 && nPast + nNew <= positions.count,
            "position rows \(nPast)..<\(nPast + nNew) are not in a table of \(positions.count)")

        input.withUnsafeMutableBufferPointer { destination in
            positions.values.withUnsafeBufferPointer { table in
                vDSP_vadd(
                    destination.baseAddress!, 1, table.baseAddress! + first, 1,
                    destination.baseAddress!, 1, vDSP_Length(nNew * dim))
            }
        }
    }
}
