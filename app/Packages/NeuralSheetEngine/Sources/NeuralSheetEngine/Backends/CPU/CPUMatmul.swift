// The `ggml_mul_mat` of muscriptor.cpp's cpp/src/model.cpp, which that file marks
// `GGML_PREC_F32` so an F16 weight is still accumulated in fp32. Here the accumulation
// is always fp32 and the activations are never rounded to half, which is the one place
// this port is closer to the fp32 reference than ggml's CPU backend is.
//
// The weight is row-major `[outFeatures][inFeatures]`: a GGUF tensor with
// `ne = [inFeatures, outFeatures]`, so one output feature's weights are contiguous.
// That is the layout a GEMV wants, and the transposed operand of a GEMM.

import Accelerate
import Dispatch

enum CPUMatmul {
    /// `out[r][o] = Σ_i W[o][i] · x[r][i]` for F16 weights.
    ///
    /// The two paths are the same arithmetic at different shapes. A decode step has one
    /// row, where the whole weight is streamed once for a single dot product per output
    /// feature: that is memory-bound, so it runs as a hand-written `Float16` SIMD GEMV
    /// with the output features split over the cores, and converting the weight to F32
    /// first would double the bytes read for no gain. A prefill has hundreds of rows,
    /// where the weight is read once per sixteen or so columns of output, so the
    /// conversion pays for itself and `cblas_sgemm` is far better than anything written
    /// here.
    ///
    /// `scratch` is the caller's, at least `outFeatures · inFeatures` floats, and is only
    /// touched when `rows > 1`.
    static func matmulF16(
        weights: UnsafePointer<Float16>, outFeatures: Int, inFeatures: Int,
        input: UnsafePointer<Float>, rows: Int,
        output: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>
    ) {
        guard rows > 1 else {
            gemv(
                weights: weights, outFeatures: outFeatures, inFeatures: inFeatures,
                input: input, output: output)
            return
        }

        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: UnsafeRawPointer(weights)),
            height: vImagePixelCount(outFeatures), width: vImagePixelCount(inFeatures),
            rowBytes: inFeatures * MemoryLayout<Float16>.stride)
        var destination = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: vImagePixelCount(outFeatures), width: vImagePixelCount(inFeatures),
            rowBytes: inFeatures * MemoryLayout<Float>.stride)
        // No `kvImageDoNotTile`: a prefill's weight is millions of values and this call is
        // made from one thread, so vImage is welcome to spread the conversion itself.
        vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))

        gemm(
            weights: scratch, outFeatures: outFeatures, inFeatures: inFeatures,
            input: input, rows: rows, output: output)
    }

    /// The F32 form, for the conditioning projection and for the tests.
    static func matmulF32(
        weights: UnsafePointer<Float>, outFeatures: Int, inFeatures: Int,
        input: UnsafePointer<Float>, rows: Int, output: UnsafeMutablePointer<Float>
    ) {
        gemm(
            weights: weights, outFeatures: outFeatures, inFeatures: inFeatures,
            input: input, rows: rows, output: output)
    }

    /// `C = A · Bᵀ`: the weight is the transposed operand because its rows run along
    /// `inFeatures`. Correct for one row as well, which is why `matmulF32` needs no
    /// special case.
    private static func gemm(
        weights: UnsafePointer<Float>, outFeatures: Int, inFeatures: Int,
        input: UnsafePointer<Float>, rows: Int, output: UnsafeMutablePointer<Float>
    ) {
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(rows), Int32(outFeatures), Int32(inFeatures),
            1, input, Int32(inFeatures), weights, Int32(inFeatures),
            0, output, Int32(outFeatures))
    }

    /// One row: a dot product of `x` with each row of the weight, reading the F16 weight
    /// straight out of the memory-mapped checkpoint.
    ///
    /// Four independent accumulators, because the loop is a chain of dependent
    /// multiply-adds otherwise and the latency, not the throughput, would set the pace.
    /// The blocks of eight are loaded unaligned: a weight row starts wherever the tensor
    /// data does.
    ///
    /// Output features go out in blocks of sixteen so that a core takes enough work to be
    /// worth the hand-off, and the reduction order is fixed rather than left to a library,
    /// so two runs on the same input give the same bits.
    private static func gemv(
        weights: UnsafePointer<Float16>, outFeatures: Int, inFeatures: Int,
        input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>
    ) {
        let featuresPerBlock = 16
        let blocks = (outFeatures + featuresPerBlock - 1) / featuresPerBlock
        let x = UnsafeRawPointer(input)

        DispatchQueue.concurrentPerform(iterations: blocks) { block in
            let first = block * featuresPerBlock
            let last = min(first + featuresPerBlock, outFeatures)
            for feature in first..<last {
                let row = UnsafeRawPointer(weights + feature * inFeatures)
                var a0 = SIMD8<Float>()
                var a1 = SIMD8<Float>()
                var a2 = SIMD8<Float>()
                var a3 = SIMD8<Float>()

                var index = 0
                while index + 32 <= inFeatures {
                    a0 += half(row, index) * single(x, index)
                    a1 += half(row, index + 8) * single(x, index + 8)
                    a2 += half(row, index + 16) * single(x, index + 16)
                    a3 += half(row, index + 24) * single(x, index + 24)
                    index += 32
                }
                while index + 8 <= inFeatures {
                    a0 += half(row, index) * single(x, index)
                    index += 8
                }

                let folded = (a0 + a1) + (a2 + a3)
                var sum =
                    (folded[0] + folded[1]) + (folded[2] + folded[3])
                    + ((folded[4] + folded[5]) + (folded[6] + folded[7]))
                // The checkpoints' shapes are all multiples of 32, so this tail never
                // runs there; it is here so that a shape that is not cannot fail quietly.
                while index < inFeatures {
                    sum += Float(weights[feature * inFeatures + index]) * input[index]
                    index += 1
                }
                output[feature] = sum
            }
        }
    }

    /// Eight F16 weights at `index`, widened to F32.
    ///
    /// The widening is spelled out lane by lane rather than as `SIMD8<Float>(someSIMD8Float16)`.
    /// That conversion looks like the obvious one and is not: the generic
    /// `SIMD8.init<Other: BinaryFloatingPoint>` does not specialise into a pair of `fcvtl`
    /// instructions but into an out-of-line call that checks an OS availability version on
    /// every invocation, which on this GEMV's hundred million weights a token was eighteen
    /// times the cost of the conversion itself. Eight `Float(Float16)` conversions into a
    /// vector literal is the form the optimiser does turn into `fcvtl`/`fcvtl2`. The two are
    /// bit-identical -- every F16, subnormals included, is exactly representable in F32 --
    /// so this is a code-generation fix and not a numerical change.
    private static func half(_ row: UnsafeRawPointer, _ index: Int) -> SIMD8<Float> {
        let halves = row.loadUnaligned(
            fromByteOffset: index * MemoryLayout<Float16>.stride, as: SIMD8<Float16>.self)

        return SIMD8<Float>(
            Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]),
            Float(halves[4]), Float(halves[5]), Float(halves[6]), Float(halves[7]))
    }

    /// Eight F32 activations at `index`.
    private static func single(_ x: UnsafeRawPointer, _ index: Int) -> SIMD8<Float> {
        x.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: SIMD8<Float>.self)
    }
}
