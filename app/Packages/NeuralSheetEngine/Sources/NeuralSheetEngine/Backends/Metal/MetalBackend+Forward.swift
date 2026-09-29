// The op order of `buildEvalGraph` in muscriptor.cpp's cpp/src/model.cpp, encoded as
// dispatches instead of built as a ggml graph. It is deliberately line for line the same
// as `CPUBackend.forward`: the two are checked against each other on identical input
// (MetalOracleTests.cpuAndMetalLogitsAgree), and the way to keep that check meaningful is
// for a reader to be able to put the two files side by side.

import Foundation
import Metal

extension MetalBackend {
    /// One command buffer, one compute encoder, every dispatch in order, then a wait.
    ///
    /// A compute encoder made by `makeComputeCommandEncoder()` dispatches serially, so Metal
    /// orders the dispatches and inserts the barriers between them: each one sees everything
    /// the last one wrote, which is what lets this read like straight-line code.
    ///
    /// One command buffer per pass rather than one per layer because the wait, not the
    /// encoding, is what costs: a decode step is a hundred dispatches of a few microseconds
    /// each, and batching them into one submission is the difference between a millisecond
    /// and ten. @see TransformerBackend
    func forward(input: [Float], nNew: Int, nPast: Int) throws -> [Float] {
        let dim = hparams.dim
        let ffnDim = hparams.ffnDim

        guard nNew > 0, input.count == nNew * dim else {
            throw TranscriberError.internalError(
                "the layer input has \(input.count) values, expected \(nNew * dim)")
        }

        guard nPast >= 0, nPast + nNew <= contextSize else {
            throw TranscriberError.contextOverflow
        }

        let nKV = nPast + nNew
        let fuseAttention = kernels.canFuseAttention(nNew: nNew, nKV: nKV, headDim: hparams.headDim)
        try reserve(nNew: nNew, nKV: nKV, scoresNeeded: !fuseAttention)

        input.withUnsafeBytes { bytes -> Void in
            memcpy(x.buffer.contents(), bytes.baseAddress!, bytes.count)
        }

        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw TranscriberError.internalError("the Metal queue would not make a command buffer")
        }

        let attention = MetalKernels.AttentionParams(
            nNew: UInt32(nNew), nKV: UInt32(nKV), nPast: UInt32(nPast), nHead: UInt32(hparams.nHead),
            headDim: UInt32(hparams.headDim), dim: UInt32(dim), scale: attentionScale)

        for layer in layers {
            kernels.layerNorm(
                encoder, x: x.buffer, xOffset: 0, out: normed.buffer, outOffset: 0,
                norms: weightsBuffer, weightOffset: layer.attnNormW, biasOffset: layer.attnNormB,
                rows: nNew, dim: dim, eps: hparams.layerNormEps)

            // `attn_qkv` is [3 . dim][dim] with q, k and v stacked in that order, so one
            // product gives all three and each is a column slice of the result.
            kernels.matrixProduct(
                encoder, weights: weightsBuffer, weightsOffset: layer.qkv,
                input: normed.buffer, inputOffset: 0, output: qkv.buffer, outputOffset: 0,
                outFeatures: 3 * dim, inFeatures: dim, rows: nNew)

            // The keys and values of this window join the cache before the attention reads
            // it, because a query at position `nPast + i` attends to its own key.
            kernels.copyKV(
                encoder, qkv: qkv.buffer, cache: cacheBuffer, keysOffset: layer.keys,
                valuesOffset: layer.values, nNew: nNew, nPast: nPast, dim: dim)

            // One kernel for a decode step and three for a prefill, which is the whole
            // difference between the two shapes: at a single query row the score row is short
            // enough to stay in threadgroup memory and nothing is masked, so writing it out
            // for two more kernels to read back is most of the cost. @see canFuseAttention
            if fuseAttention {
                kernels.attentionDecode(
                    encoder, qkv: qkv.buffer, cache: cacheBuffer, keysOffset: layer.keys,
                    valuesOffset: layer.values, out: attended.buffer, attention: attention)
            } else {
                kernels.attentionScores(
                    encoder, qkv: qkv.buffer, cache: cacheBuffer, keysOffset: layer.keys,
                    scores: scores.buffer, attention: attention)
                kernels.softmaxRows(
                    encoder, scores: scores.buffer, rows: hparams.nHead * nNew, columns: nKV)
                kernels.attentionValues(
                    encoder, scores: scores.buffer, cache: cacheBuffer, valuesOffset: layer.values,
                    out: attended.buffer, attention: attention)
            }

            kernels.matrixProduct(
                encoder, weights: weightsBuffer, weightsOffset: layer.attnOut,
                input: attended.buffer, inputOffset: 0, output: projected.buffer, outputOffset: 0,
                outFeatures: dim, inFeatures: dim, rows: nNew)
            kernels.add(encoder, y: x.buffer, x: projected.buffer, count: nNew * dim)

            kernels.layerNorm(
                encoder, x: x.buffer, xOffset: 0, out: normed.buffer, outOffset: 0,
                norms: weightsBuffer, weightOffset: layer.ffnNormW, biasOffset: layer.ffnNormB,
                rows: nNew, dim: dim, eps: hparams.layerNormEps)
            kernels.matrixProduct(
                encoder, weights: weightsBuffer, weightsOffset: layer.ffnUp,
                input: normed.buffer, inputOffset: 0, output: ffn.buffer, outputOffset: 0,
                outFeatures: ffnDim, inFeatures: dim, rows: nNew)
            kernels.gelu(encoder, x: ffn.buffer, count: nNew * ffnDim)

            // Into `projected` again: the attention residual has already been added, so that
            // buffer is free, and the two products are never live at the same time.
            kernels.matrixProduct(
                encoder, weights: weightsBuffer, weightsOffset: layer.ffnDown,
                input: ffn.buffer, inputOffset: 0, output: projected.buffer, outputOffset: 0,
                outFeatures: dim, inFeatures: ffnDim, rows: nNew)
            kernels.add(encoder, y: x.buffer, x: projected.buffer, count: nNew * dim)
        }

        // Only the last position is ever sampled, so the output norm and the LM head run on
        // one row however wide the window was. The row is reached with a buffer offset, which
        // is why every offset above is spelled out rather than assumed to be zero.
        kernels.layerNorm(
            encoder, x: x.buffer, xOffset: (nNew - 1) * dim * 4, out: normed.buffer, outOffset: 0,
            norms: weightsBuffer, weightOffset: outputNormW, biasOffset: outputNormB,
            rows: 1, dim: dim, eps: hparams.layerNormEps)
        kernels.matrixProduct(
            encoder, weights: weightsBuffer, weightsOffset: outputHead,
            input: normed.buffer, inputOffset: 0, output: logitsBuffer, outputOffset: 0,
            outFeatures: hparams.vocabSize, inFeatures: dim, rows: 1)

        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        if let error = commands.error {
            throw TranscriberError.internalError("the Metal forward pass failed: \(error.localizedDescription)")
        }

        return Array(
            UnsafeBufferPointer(
                start: logitsBuffer.contents().assumingMemoryBound(to: Float.self), count: hparams.vocabSize))
    }

    /// Grows the activation buffers to fit this window. A prefill grows them once; every
    /// decode step after it is a single row over the same buffers and allocates nothing.
    private func reserve(nNew: Int, nKV: Int, scoresNeeded: Bool) throws {
        let dim = hparams.dim
        try x.reserve(nNew * dim)
        try normed.reserve(nNew * dim)
        try qkv.reserve(nNew * 3 * dim)
        try attended.reserve(nNew * dim)
        try projected.reserve(nNew * dim)
        try ffn.reserve(nNew * hparams.ffnDim)

        // Only the three-kernel path has an `nNew x nKV` block per head to write; the fused
        // decode kernel keeps its row in threadgroup memory, so a run that never prefills at a
        // wider window -- which no chunk is -- never allocates this at all.
        if scoresNeeded {
            try scores.reserve(hparams.nHead * nNew * nKV)
        }
    }
}
