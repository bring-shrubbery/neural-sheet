// The dispatch side of the kernels in MetalShaderSource, which is what ggml's
// `ggml_metal_encode_node` does for muscriptor.cpp's graph: pick the pipeline, bind the
// buffers, work out the grid. Splitting it from the backend keeps `forward` readable as
// the op order of `buildEvalGraph` rather than as three hundred lines of `setBuffer`.

import Foundation
import Metal

extension MetalKernels {
    // The parameter blocks, mirroring the MSL structs field for field. Every field is
    // four bytes so that neither side needs a padding rule, and they are passed with
    // `setBytes`, which copies into the command buffer: one block per dispatch, no
    // buffer to allocate and no lifetime to manage.

    struct LayerNormParams {
        var dim: UInt32
        var eps: Float
    }

    struct MatmulParams {
        var outFeatures: UInt32
        var inFeatures: UInt32
        var rows: UInt32
    }

    struct CopyKVParams {
        var dim: UInt32
        var nPast: UInt32
    }

    struct AttentionParams {
        var nNew: UInt32
        var nKV: UInt32
        var nPast: UInt32
        var nHead: UInt32
        var headDim: UInt32
        var dim: UInt32
        var scale: Float
    }

    struct SoftmaxParams {
        var columns: UInt32
    }
}

/// The compiled pipelines and the grids they are dispatched over.
///
/// A value type over `MTLComputePipelineState`s, which are themselves immutable and
/// thread-safe; the encoder a method is handed is the caller's, and this holds no state
/// between calls.
struct MetalKernels {
    /// `REDUCE_THREADS` in the shader source. The reduction kernels' threadgroup arrays
    /// are this long and their trees halve it, so the dispatch must match it exactly.
    static let reduceThreads = 256

    /// The block `matvec_f16` was compiled with, which is what its grid and its threadgroup
    /// have to be built from. Read from the shader source rather than restated here: one
    /// definition feeds both the `#define`s and this. @see MetalShaderSource.matvecBlock
    static var matvecBlock: MetalShaderSource.MatvecBlock { MetalShaderSource.matvecBlock }

    /// The tile `matmul_tiled_f16` was compiled with, which is what its grid has to be built
    /// from. Read from the shader source rather than restated here: one definition feeds both
    /// the `#define`s and this. @see MetalShaderSource.gemmTile
    static var gemmTile: MetalShaderSource.GEMMTile { MetalShaderSource.gemmTile }

    /// The threadgroup `matmul_tiled_f16` is dispatched with, which is `GEMM_THREADS`.
    static var gemmThreads: MTLSize { MTLSize(width: gemmTile.threads, height: 1, depth: 1) }

    private let layerNormState: MTLComputePipelineState
    private let matvecState: MTLComputePipelineState
    private let matmulState: MTLComputePipelineState
    private let copyKVState: MTLComputePipelineState
    private let attentionScoresState: MTLComputePipelineState
    private let softmaxState: MTLComputePipelineState
    private let attentionValuesState: MTLComputePipelineState
    private let geluState: MTLComputePipelineState
    private let addState: MTLComputePipelineState

    /// The threadgroup `matvec_f16` is dispatched with: `MATVEC_SIMDGROUPS` whole
    /// simdgroups, because the kernel reduces with `simd_sum` and indexes its block by
    /// `simdgroup_index_in_threadgroup`.
    private let matvecThreads: MTLSize

    /// Threadgroup shapes for the kernels dispatched by thread count rather than by
    /// threadgroup, computed once from each pipeline's own limits.
    private let planeThreads: MTLSize
    private let lineThreads: MTLSize

    /// `.internalError` when a kernel is missing from the library, when a pipeline will not
    /// build, or when the device cannot run a 256-thread threadgroup -- which no Apple GPU
    /// cannot, and which the reduction kernels have no fallback for.
    init(device: MTLDevice, library: MTLLibrary) throws {
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw TranscriberError.internalError("the Metal library has no kernel '\(name)'")
            }

            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw TranscriberError.internalError(
                    "the Metal kernel '\(name)' would not build: \(error.localizedDescription)")
            }
        }

        layerNormState = try state("layer_norm")
        matvecState = try state("matvec_f16")
        matmulState = try state("matmul_tiled_f16")
        copyKVState = try state("copy_kv")
        attentionScoresState = try state("attn_scores")
        softmaxState = try state("softmax_rows")
        attentionValuesState = try state("attn_values")
        geluState = try state("gelu_erf")
        addState = try state("add_inplace")

        let reduce = MetalKernels.reduceThreads

        guard layerNormState.maxTotalThreadsPerThreadgroup >= reduce,
            softmaxState.maxTotalThreadsPerThreadgroup >= reduce
        else {
            throw TranscriberError.internalError(
                "this device runs fewer than \(reduce) threads per threadgroup")
        }

        let matvecWidth = max(1, matvecState.threadExecutionWidth) * MetalKernels.matvecBlock.simdgroups

        guard matvecState.maxTotalThreadsPerThreadgroup >= matvecWidth else {
            throw TranscriberError.internalError(
                "this device runs fewer than \(matvecWidth) threads per threadgroup")
        }

        matvecThreads = MTLSize(width: matvecWidth, height: 1, depth: 1)

        // `matmul_tiled_f16` has its tile compiled into it, so unlike the kernels below it
        // cannot be shaped to the device: the dispatch is the one the macros imply or the
        // kernel reads past its threadgroup arrays.
        guard matmulState.maxTotalThreadsPerThreadgroup >= MetalKernels.gemmThreads.width else {
            throw TranscriberError.internalError(
                "this device runs fewer than \(MetalKernels.gemmThreads.width) threads per threadgroup")
        }

        // A 2D or 3D grid is covered with the execution width along x -- so that the lanes
        // of a simdgroup read consecutive addresses -- and as many rows of that as the
        // pipeline will take, capped at eight because none of those kernels is bound by
        // occupancy. The limits are the smallest of every pipeline the shape is used for,
        // because a threadgroup wider than a pipeline allows is a dispatch Metal rejects.
        let planeWidth = max(1, attentionScoresState.threadExecutionWidth)
        let planeLimit = min(
            copyKVState.maxTotalThreadsPerThreadgroup,
            min(attentionScoresState.maxTotalThreadsPerThreadgroup, attentionValuesState.maxTotalThreadsPerThreadgroup))
        planeThreads = MTLSize(
            width: planeWidth, height: max(1, min(8, planeLimit / planeWidth)), depth: 1)

        let lineLimit = min(geluState.maxTotalThreadsPerThreadgroup, addState.maxTotalThreadsPerThreadgroup)
        lineThreads = MTLSize(width: max(1, min(256, lineLimit)), height: 1, depth: 1)
    }

    /// LayerNorm of `rows` rows of `dim` values. The offsets are byte offsets into their
    /// buffers, which is how a single-row norm reads the last row of a window.
    func layerNorm(
        _ encoder: MTLComputeCommandEncoder,
        x: MTLBuffer, xOffset: Int, out: MTLBuffer, outOffset: Int,
        norms: MTLBuffer, weightOffset: Int, biasOffset: Int,
        rows: Int, dim: Int, eps: Float
    ) {
        var params = LayerNormParams(dim: UInt32(dim), eps: eps)
        encoder.setComputePipelineState(layerNormState)
        encoder.setBuffer(x, offset: xOffset, index: 0)
        encoder.setBuffer(out, offset: outOffset, index: 1)
        encoder.setBuffer(norms, offset: weightOffset, index: 2)
        encoder.setBuffer(norms, offset: biasOffset, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<LayerNormParams>.stride, index: 4)
        encoder.dispatchThreadgroups(
            MTLSize(width: rows, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: MetalKernels.reduceThreads, height: 1, depth: 1))
    }

    /// `out[r][o] = sum_i W[o][i] . x[r][i]`, over `rows` rows of `inFeatures` values.
    ///
    /// One kernel or the other by the row count, which is the whole difference between a
    /// decode step and a prefill: `matvec_f16` puts a simdgroup on each block of output rows
    /// of the single input row and is bound by the weight it streams, `matmul_tiled_f16`
    /// tiles the output and is bound by the arithmetic.
    func matrixProduct(
        _ encoder: MTLComputeCommandEncoder,
        weights: MTLBuffer, weightsOffset: Int, input: MTLBuffer, inputOffset: Int,
        output: MTLBuffer, outputOffset: Int, outFeatures: Int, inFeatures: Int, rows: Int
    ) {
        var params = MatmulParams(
            outFeatures: UInt32(outFeatures), inFeatures: UInt32(inFeatures), rows: UInt32(rows))
        encoder.setComputePipelineState(rows == 1 ? matvecState : matmulState)
        encoder.setBuffer(weights, offset: weightsOffset, index: 0)
        encoder.setBuffer(input, offset: inputOffset, index: 1)
        encoder.setBuffer(output, offset: outputOffset, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<MatmulParams>.stride, index: 3)

        if rows == 1 {
            // Whole threadgroups: a block of `rowsPerGroup` output rows is the unit of work,
            // and a ragged one at the end is the kernel's own business -- it clamps the rows
            // it reads and stores only the ones that exist.
            let block = MetalKernels.matvecBlock.rowsPerGroup
            encoder.dispatchThreadgroups(
                MTLSize(width: (outFeatures + block - 1) / block, height: 1, depth: 1),
                threadsPerThreadgroup: matvecThreads)
        } else {
            // Whole threadgroups, not threads: a tile is the unit of work, and a partial one
            // at the edge of either axis is the kernel's own business -- it stages zeroes for
            // what is not there and writes back only what is.
            let tile = MetalKernels.gemmTile
            encoder.dispatchThreadgroups(
                MTLSize(
                    width: (outFeatures + tile.features - 1) / tile.features,
                    height: (rows + tile.rows - 1) / tile.rows, depth: 1),
                threadsPerThreadgroup: MetalKernels.gemmThreads)
        }
    }

    /// This window's keys and values into the cache at rows `nPast ..< nPast + nNew`.
    func copyKV(
        _ encoder: MTLComputeCommandEncoder,
        qkv: MTLBuffer, cache: MTLBuffer, keysOffset: Int, valuesOffset: Int,
        nNew: Int, nPast: Int, dim: Int
    ) {
        var params = CopyKVParams(dim: UInt32(dim), nPast: UInt32(nPast))
        encoder.setComputePipelineState(copyKVState)
        encoder.setBuffer(qkv, offset: 0, index: 0)
        encoder.setBuffer(cache, offset: keysOffset, index: 1)
        encoder.setBuffer(cache, offset: valuesOffset, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<CopyKVParams>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: dim, height: nNew, depth: 1), threadsPerThreadgroup: planeThreads)
    }

    /// The scaled, causally masked scores of every (key, query, head).
    func attentionScores(
        _ encoder: MTLComputeCommandEncoder,
        qkv: MTLBuffer, cache: MTLBuffer, keysOffset: Int, scores: MTLBuffer, attention: AttentionParams
    ) {
        var params = attention
        encoder.setComputePipelineState(attentionScoresState)
        encoder.setBuffer(qkv, offset: 0, index: 0)
        encoder.setBuffer(cache, offset: keysOffset, index: 1)
        encoder.setBuffer(scores, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<AttentionParams>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: Int(attention.nKV), height: Int(attention.nNew), depth: Int(attention.nHead)),
            threadsPerThreadgroup: planeThreads)
    }

    /// Softmax in place over each of `rows` rows of `columns` values.
    func softmaxRows(_ encoder: MTLComputeCommandEncoder, scores: MTLBuffer, rows: Int, columns: Int) {
        var params = SoftmaxParams(columns: UInt32(columns))
        encoder.setComputePipelineState(softmaxState)
        encoder.setBuffer(scores, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<SoftmaxParams>.stride, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: rows, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: MetalKernels.reduceThreads, height: 1, depth: 1))
    }

    /// The weighted sum of the cached values into `[nNew][dim]`.
    func attentionValues(
        _ encoder: MTLComputeCommandEncoder,
        scores: MTLBuffer, cache: MTLBuffer, valuesOffset: Int, out: MTLBuffer, attention: AttentionParams
    ) {
        var params = attention
        encoder.setComputePipelineState(attentionValuesState)
        encoder.setBuffer(scores, offset: 0, index: 0)
        encoder.setBuffer(cache, offset: valuesOffset, index: 1)
        encoder.setBuffer(out, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<AttentionParams>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(
                width: Int(attention.headDim), height: Int(attention.nNew), depth: Int(attention.nHead)),
            threadsPerThreadgroup: planeThreads)
    }

    /// GELU in place over `count` activations.
    func gelu(_ encoder: MTLComputeCommandEncoder, x: MTLBuffer, count: Int) {
        encoder.setComputePipelineState(geluState)
        encoder.setBuffer(x, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: lineThreads)
    }

    /// `y += x` over `count` values.
    func add(_ encoder: MTLComputeCommandEncoder, y: MTLBuffer, x: MTLBuffer, count: Int) {
        encoder.setComputePipelineState(addState)
        encoder.setBuffer(y, offset: 0, index: 0)
        encoder.setBuffer(x, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: lineThreads)
    }
}
