// Ported from `buildEvalGraph` in muscriptor.cpp's cpp/src/model.cpp: the same ops per
// layer in the same order, written out as calls instead of built as a ggml graph.
//
// Two departures from the reference, both deliberate. The values cache is not transposed,
// because the transpose there existed to suit ggml's matmul and ours wants the plain
// layout (see CPUAttention). And the causal mask is not a tensor: it is a prefix length
// per query row, which is the same arithmetic without an `nNew × nKV` buffer of zeroes and
// infinities to build and read on every pass.

import Accelerate
import Foundation

/// The transformer stack on the CPU: Accelerate for the matrix products, this file for the
/// order they run in.
///
/// The weights are never copied. `file` is held for the life of the backend and every
/// `Float16` pointer below addresses its mapping directly, which is what lets a decode step
/// touch 200 MB of weights without a single allocation.
///
/// One call at a time; nothing here is thread-safe. @see TransformerBackend
final class CPUBackend: TransformerBackend {
    let name = "CPU"
    let contextSize: Int

    /// The mapping every weight pointer below points into; dropping it would unmap them.
    private let file: GGUFFile

    private let hparams: Hparams

    /// `1 / sqrt(headDim)`, the attention scale, computed once in `Float` as the C++ does.
    private let attentionScale: Float

    /// One block's weights and its slice of the KV cache.
    private struct Layer {
        var attnNormW: UnsafePointer<Float>
        var attnNormB: UnsafePointer<Float>
        var ffnNormW: UnsafePointer<Float>
        var ffnNormB: UnsafePointer<Float>
        var qkv: UnsafePointer<Float16>
        var attnOut: UnsafePointer<Float16>
        var ffnUp: UnsafePointer<Float16>
        var ffnDown: UnsafePointer<Float16>
        var keys: UnsafeMutablePointer<Float>
        var values: UnsafeMutablePointer<Float>
    }

    private let layers: [Layer]
    private let outputNormW: UnsafePointer<Float>
    private let outputNormB: UnsafePointer<Float>
    private let outputHead: UnsafePointer<Float16>

    /// Every layer norm's weight and bias in one F32 allocation, in layer order, with the
    /// output norm's pair last. The checkpoint stores them as F32 already, but as separate
    /// tensors, and a pass reads each of them once per layer, so they are gathered here
    /// rather than pointed at in the mapping: (14 x 4 + 2) x 768 x 4 = 178 kB in one
    /// allocation for the small checkpoint, instead of 58 tensors scattered through it.
    private let normStore: UnsafeMutablePointer<Float>

    /// K and V for every layer, `[nCtx][dim]` each, in one allocation. This is the biggest
    /// thing the engine owns -- 218 MB for the small checkpoint at nCtx = 2538 -- and it is
    /// exactly what the C++ allocates for the same context.
    private let cacheStore: UnsafeMutablePointer<Float>

    /// `[vocabSize]`, the only buffer whose size never depends on the window.
    private let logits: UnsafeMutablePointer<Float>

    /// `matmulF16`'s F32 copy of one weight, for the prefill path. Big enough for the
    /// largest matrix in the model, so it is allocated once and reused by every call.
    private let weightScratch: UnsafeMutablePointer<Float>

    // The activations. Their sizes are the window's, so they are grown by `reserve` rather
    // than fixed at init: sizing them for a window of `contextSize` rows would mean a
    // 300 MB scores buffer for a window the engine never feeds.
    private let x = FloatScratch()
    private let normed = FloatScratch()
    private let qkv = FloatScratch()
    private let attended = FloatScratch()
    private let projected = FloatScratch()
    private let ffn = FloatScratch()
    private let scores = FloatScratch()

    /// `.invalidCheckpoint` when a tensor is not the type or the extent the hyperparameters
    /// say it is: every pointer below is read without bounds checks afterwards, so the
    /// shapes are established here or not at all.
    init(file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int) throws {
        guard contextSize > 0 else {
            throw TranscriberError.internalError("context size must be positive, not \(contextSize)")
        }

        let dim = hparams.dim
        let nLayer = hparams.nLayer
        let normCount = (nLayer * 4 + 2) * dim
        let cacheCount = nLayer * 2 * contextSize * dim
        let scratchCount = max(3 * dim * dim, max(hparams.ffnDim * dim, hparams.vocabSize * dim))

        let norms = UnsafeMutablePointer<Float>.allocate(capacity: normCount)
        norms.initialize(repeating: 0, count: normCount)
        let caches = UnsafeMutablePointer<Float>.allocate(capacity: cacheCount)
        caches.initialize(repeating: 0, count: cacheCount)
        let logitRow = UnsafeMutablePointer<Float>.allocate(capacity: hparams.vocabSize)
        logitRow.initialize(repeating: 0, count: hparams.vocabSize)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
        scratch.initialize(repeating: 0, count: scratchCount)

        // A throwing initialiser runs no deinit, so a rejected checkpoint would leak all four
        // of the allocations above. Nothing is stored in a property until every tensor has
        // been accepted, which is what lets this release them without reaching for `self`.
        var accepted = false
        defer {
            if !accepted {
                norms.deallocate()
                caches.deallocate()
                logitRow.deallocate()
                scratch.deallocate()
            }
        }

        // The two output-norm vectors go at the end of the store, so a layer's four sit
        // together at `layer * 4 * dim`.
        try CPUBackend.copyFloats(file, weights.outputNormW, into: norms + nLayer * 4 * dim, count: dim)
        try CPUBackend.copyFloats(file, weights.outputNormB, into: norms + (nLayer * 4 + 1) * dim, count: dim)
        let head = try CPUBackend.halves(file, weights.output, count: hparams.vocabSize * dim)

        let blocks = try (0 ..< nLayer).map { index -> Layer in
            let layer = weights.layers[index]
            let block = norms + index * 4 * dim
            try CPUBackend.copyFloats(file, layer.attnNormW, into: block, count: dim)
            try CPUBackend.copyFloats(file, layer.attnNormB, into: block + dim, count: dim)
            try CPUBackend.copyFloats(file, layer.ffnNormW, into: block + 2 * dim, count: dim)
            try CPUBackend.copyFloats(file, layer.ffnNormB, into: block + 3 * dim, count: dim)

            return Layer(
                attnNormW: UnsafePointer(block),
                attnNormB: UnsafePointer(block + dim),
                ffnNormW: UnsafePointer(block + 2 * dim),
                ffnNormB: UnsafePointer(block + 3 * dim),
                qkv: try CPUBackend.halves(file, layer.attnQKV, count: 3 * dim * dim),
                attnOut: try CPUBackend.halves(file, layer.attnOut, count: dim * dim),
                ffnUp: try CPUBackend.halves(file, layer.ffnUp, count: hparams.ffnDim * dim),
                ffnDown: try CPUBackend.halves(file, layer.ffnDown, count: dim * hparams.ffnDim),
                keys: caches + (index * 2) * contextSize * dim,
                values: caches + (index * 2 + 1) * contextSize * dim)
        }

        self.file = file
        self.hparams = hparams
        self.contextSize = contextSize
        attentionScale = 1 / sqrt(Float(hparams.headDim))
        normStore = norms
        cacheStore = caches
        logits = logitRow
        weightScratch = scratch
        outputNormW = UnsafePointer(norms + nLayer * 4 * dim)
        outputNormB = UnsafePointer(norms + (nLayer * 4 + 1) * dim)
        outputHead = head
        layers = blocks
        accepted = true
    }

    deinit {
        normStore.deallocate()
        cacheStore.deallocate()
        logits.deallocate()
        weightScratch.deallocate()
    }

    /// The reference zeroes the cache here too. Nothing reads past the filled rows, so this
    /// is not needed for correctness -- it is here so that an off-by-one in the causal bound
    /// shows up as an obviously wrong number rather than as a plausible one.
    func reset() {
        let count = hparams.nLayer * 2 * contextSize * hparams.dim
        vDSP_vclr(cacheStore, 1, vDSP_Length(count))
    }

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
        reserve(nNew: nNew, nKV: nKV)

        let activations = x.pointer
        let normed = self.normed.pointer
        let qkv = self.qkv.pointer
        let attended = self.attended.pointer
        let projected = self.projected.pointer
        let ffn = self.ffn.pointer
        let scores = self.scores.pointer

        input.withUnsafeBufferPointer { activations.update(from: $0.baseAddress!, count: nNew * dim) }

        for layer in layers {
            CPUKernels.layerNorm(
                activations, rows: nNew, dim: dim, weight: layer.attnNormW, bias: layer.attnNormB,
                eps: hparams.layerNormEps, out: normed)

            // `attn_qkv` is [3 · dim][dim] with q, k and v stacked in that order, so one
            // product gives all three and each is a column slice of the result.
            CPUMatmul.matmulF16(
                weights: layer.qkv, outFeatures: 3 * dim, inFeatures: dim,
                input: normed, rows: nNew, output: qkv, scratch: weightScratch)

            // The keys and values of this window join the cache before the attention reads
            // it, because a query at position `nPast + i` attends to its own key.
            for row in 0 ..< nNew {
                let source = qkv + row * 3 * dim
                (layer.keys + (nPast + row) * dim).update(from: source + dim, count: dim)
                (layer.values + (nPast + row) * dim).update(from: source + 2 * dim, count: dim)
            }

            CPUAttention.attend(
                q: qkv, qRowStride: 3 * dim, kCache: layer.keys, vCache: layer.values,
                nNew: nNew, nPast: nPast, nHead: hparams.nHead, headDim: hparams.headDim,
                scale: attentionScale, scores: scores, out: attended)

            CPUMatmul.matmulF16(
                weights: layer.attnOut, outFeatures: dim, inFeatures: dim,
                input: attended, rows: nNew, output: projected, scratch: weightScratch)
            CPUKernels.add(activations, projected, count: nNew * dim)

            CPUKernels.layerNorm(
                activations, rows: nNew, dim: dim, weight: layer.ffnNormW, bias: layer.ffnNormB,
                eps: hparams.layerNormEps, out: normed)
            CPUMatmul.matmulF16(
                weights: layer.ffnUp, outFeatures: ffnDim, inFeatures: dim,
                input: normed, rows: nNew, output: ffn, scratch: weightScratch)
            CPUKernels.geluErf(ffn, count: nNew * ffnDim)

            // Into `projected` again: the attention residual has already been added, so that
            // buffer is free, and the two products are never live at the same time.
            CPUMatmul.matmulF16(
                weights: layer.ffnDown, outFeatures: dim, inFeatures: ffnDim,
                input: ffn, rows: nNew, output: projected, scratch: weightScratch)
            CPUKernels.add(activations, projected, count: nNew * dim)
        }

        // Only the last position is ever sampled, so the output norm and the LM head run on
        // one row however wide the window was.
        CPUKernels.layerNorm(
            activations + (nNew - 1) * dim, rows: 1, dim: dim, weight: outputNormW, bias: outputNormB,
            eps: hparams.layerNormEps, out: normed)
        CPUMatmul.matmulF16(
            weights: outputHead, outFeatures: hparams.vocabSize, inFeatures: dim,
            input: normed, rows: 1, output: logits, scratch: weightScratch)

        return Array(UnsafeBufferPointer(start: logits, count: hparams.vocabSize))
    }

    /// Grows the activation buffers to fit this window. A prefill grows them once; every
    /// decode step after it is a single row over the same buffers and allocates nothing.
    private func reserve(nNew: Int, nKV: Int) {
        let dim = hparams.dim
        x.reserve(nNew * dim)
        normed.reserve(nNew * dim)
        qkv.reserve(nNew * 3 * dim)
        attended.reserve(nNew * dim)
        projected.reserve(nNew * dim)
        ffn.reserve(nNew * hparams.ffnDim)
        scores.reserve(hparams.nHead * nNew * nKV)
    }

    /// An F32 tensor of exactly `count` values, copied into `destination`.
    private static func copyFloats(
        _ file: GGUFFile, _ info: TensorInfo, into destination: UnsafeMutablePointer<Float>, count: Int
    ) throws {
        guard info.dataType == .f32, info.elementCount == count else {
            throw TranscriberError.invalidCheckpoint(
                "tensor '\(info.name)' is \(info.elementCount) values of \(info.dataType), expected \(count) f32")
        }

        try file.floats(of: info).withUnsafeBufferPointer {
            destination.update(from: $0.baseAddress!, count: count)
        }
    }

    /// An F16 tensor of exactly `count` values, as a pointer into the mapping.
    ///
    /// The GGUF's data section and every tensor offset in it are aligned to at least 32
    /// bytes, so binding the region to `Float16` is always aligned.
    private static func halves(_ file: GGUFFile, _ info: TensorInfo, count: Int) throws -> UnsafePointer<Float16> {
        guard info.dataType == .f16, info.elementCount == count else {
            throw TranscriberError.invalidCheckpoint(
                "tensor '\(info.name)' is \(info.elementCount) values of \(info.dataType), expected \(count) f16")
        }

        guard let base = file.bytes(of: info).bindMemory(to: Float16.self).baseAddress else {
            throw TranscriberError.invalidCheckpoint("tensor '\(info.name)' has no data")
        }

        return UnsafePointer(base)
    }
}

/// One growable F32 buffer.
///
/// A class rather than a struct so that the backend's `forward` can grow it through a `let`
/// property, and so that the deallocation is the buffer's own business.
private final class FloatScratch {
    private(set) var pointer: UnsafeMutablePointer<Float>
    private var capacity: Int

    init() {
        capacity = 0
        pointer = UnsafeMutablePointer<Float>.allocate(capacity: 0)
    }

    deinit {
        pointer.deallocate()
    }

    /// Grows to at least `count` values, discarding what was there. Buffers are written
    /// before they are read on every pass, so nothing is carried over and nothing is
    /// zeroed: a grow is a fresh allocation, not a copy.
    func reserve(_ count: Int) {
        guard count > capacity else { return }

        pointer.deallocate()
        pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        capacity = count
    }
}
