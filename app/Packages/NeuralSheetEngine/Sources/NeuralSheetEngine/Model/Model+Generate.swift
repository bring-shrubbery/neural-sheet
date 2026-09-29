// Ported from `Model::prefill`, `Model::decode` and `Model::generate` in muscriptor.cpp's
// cpp/src/model.cpp, with the prefix assembly of `buildEvalGraph` folded into `prefill`:
// without a compute graph there is nothing to build, only a buffer to fill.

extension Model {
    /// One chunk's opening pass: the conditioning frames, the dataset row, the instrument
    /// rows and `tokens`, all at once, over a square causal mask.
    ///
    /// The prefix order is the reference's and it is the single easiest thing to get wrong:
    /// `ConditioningProvider` iterates `{instrument_group, dataset_name, self_wav}` and each
    /// step prepends in front of what came before, so what reaches the model is the reverse
    /// of the iteration order -- the frames, then the dataset row, then the instrument rows.
    ///
    /// `.internalError` when `conditioning` is not `frameCount · dim` values or `tokens` is
    /// empty, `.contextOverflow` when the prefix does not fit in what is left of the context.
    /// Returns the last position's masked logits, `[vocabSize]`.
    func prefill(conditioning: [Float], frameCount: Int, tokens: [Int32]) throws -> [Float] {
        let dim = hparams.dim

        guard frameCount > 0 else {
            throw TranscriberError.internalError("prefill needs at least one conditioning frame")
        }

        guard conditioning.count == frameCount * dim else {
            throw TranscriberError.internalError(
                "conditioning has \(conditioning.count) values, expected \(frameCount * dim)")
        }

        guard !tokens.isEmpty else {
            throw TranscriberError.internalError("prefill needs at least one token")
        }

        let nNew = frameCount + 1 + instrumentRows.count + tokens.count

        // Before the buffer is built rather than inside the backend, so the position table is
        // never indexed past its end and an overflow costs nothing.
        guard nPast + nNew <= contextSize else {
            throw TranscriberError.contextOverflow
        }

        var input = [Float]()
        input.reserveCapacity(nNew * dim)
        input.append(contentsOf: conditioning)
        input.append(contentsOf: try embedDatasetRow())
        input.append(contentsOf: try embedInstrumentRows())
        input.append(contentsOf: try embed(tokens: tokens))
        addPositions(to: &input, nNew: nNew)

        return try run(input: input, nNew: nNew)
    }

    /// One token, one new position. @see prefill
    func decode(token: Int32) throws -> [Float] {
        guard nPast + 1 <= contextSize else {
            throw TranscriberError.contextOverflow
        }

        var input = try embed(tokens: [token])
        addPositions(to: &input, nNew: 1)
        return try run(input: input, nNew: 1)
    }

    /// The greedy loop over one chunk: `reset`, one prefill of `[initialToken] + prompt`, then
    /// argmax and decode until `eosID` or the budget.
    ///
    /// `prompt` is teacher forcing, and it is returned at the head of the answer because the
    /// decode state machine downstream has to see it to leave the tie prologue -- upstream
    /// yields it into the same stream. It is fed in the prefill rather than stepped through,
    /// which is what the reference does: it writes the prompt into `gen_sequence` and starts
    /// decoding from the end of it.
    ///
    /// `maxTokens` counts the prompt, so the answer is never longer than it -- as long as the
    /// prompt fits. A prompt longer than the budget decodes nothing and is returned whole,
    /// which is what the C++ does; `Transcriber` never asks for one, its prompt is three tokens
    /// against a budget of two thousand.
    func generate(
        conditioning: [Float], frameCount: Int, maxTokens: Int, eosID: Int32, prompt: [Int32] = []
    ) throws -> [Int32] {
        reset()

        var logits = try prefill(
            conditioning: conditioning, frameCount: frameCount,
            tokens: [Int32(hparams.initialTokenID)] + prompt)

        var out = prompt
        out.reserveCapacity(max(maxTokens, prompt.count))

        var step = prompt.count

        while step < maxTokens {
            let next = Model.argmax(logits)
            out.append(next)

            if next == eosID {
                break
            }

            // The last forward pass of a spent budget is skipped: nothing would read its
            // logits, and it would cost one more position in the cache.
            if step + 1 < maxTokens {
                logits = try decode(token: next)
            }

            step += 1
        }

        return out
    }

    /// The largest logit's id, first one winning, which is what `std::max_element` and
    /// `ggml_argmax` both do. Starts at zero rather than at -infinity so that a fully masked
    /// row still answers a token rather than -1.
    static func argmax(_ logits: [Float]) -> Int32 {
        guard !logits.isEmpty else { return 0 }

        var best = 0

        for index in 1 ..< logits.count where logits[index] > logits[best] {
            best = index
        }

        return Int32(best)
    }
}
