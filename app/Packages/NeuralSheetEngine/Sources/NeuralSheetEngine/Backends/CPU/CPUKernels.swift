// The elementwise half of the ggml ops muscriptor.cpp's cpp/src/model.cpp builds its
// graph from: `ggml_norm` followed by `ggml_mul` and `ggml_add` (its `layerNorm`
// helper), `ggml_gelu_erf`, `ggml_add` and `ggml_soft_max_ext`.
//
// These are free functions over raw pointers rather than methods on a buffer type
// because the backend already owns every allocation the forward pass needs and reuses
// it across tokens; handing a kernel a pointer and a count is what keeps a decode step
// free of allocation.

import Accelerate
import Dispatch
import Foundation

enum CPUKernels {
    /// LayerNorm with affine parameters, row by row: `(x - mean) / sqrt(var + eps) * weight + bias`.
    ///
    /// The variance is the population variance -- the sum of squared deviations over
    /// `dim`, not over `dim - 1` -- which is what `ggml_norm` computes and what PyTorch's
    /// `LayerNorm` computes. The mean and the sum of squares accumulate in `Double` for
    /// the same reason ggml's do: the row is up to 1536 wide, the cost is nothing beside
    /// the matmuls, and a drift here shifts every number in the layer.
    ///
    /// `out` may alias `x`.
    static func layerNorm(
        _ x: UnsafePointer<Float>, rows: Int, dim: Int,
        weight: UnsafePointer<Float>, bias: UnsafePointer<Float>, eps: Float,
        out: UnsafeMutablePointer<Float>
    ) {
        for row in 0..<rows {
            let source = x + row * dim
            let destination = out + row * dim

            var total = 0.0
            for index in 0..<dim {
                total += Double(source[index])
            }
            let mean = total / Double(dim)

            var squares = 0.0
            for index in 0..<dim {
                let centred = Double(source[index]) - mean
                squares += centred * centred
            }
            let inverse = Float(1 / (squares / Double(dim) + Double(eps)).squareRoot())

            var negatedMean = Float(-mean)
            vDSP_vsadd(source, 1, &negatedMean, destination, 1, vDSP_Length(dim))
            var scale = inverse
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(dim))
            vDSP_vmul(destination, 1, weight, 1, destination, 1, vDSP_Length(dim))
            vDSP_vadd(destination, 1, bias, 1, destination, 1, vDSP_Length(dim))
        }
    }

    /// GELU in its exact erf form, `0.5 x (1 + erf(x / sqrt 2))`, in place.
    ///
    /// `ggml_gelu` is the tanh approximation and `ggml_gelu_erf` is this; the reference
    /// picks this one because `torch.nn.functional.gelu` defaults to it, and the two
    /// differ by up to about 1e-3 per activation, which compounds over the layers.
    ///
    /// Accelerate has no vectorised erf -- vForce covers exp, log and the trigonometry but
    /// stops short of the error function -- so this is a scalar loop over libm's `erff`,
    /// which is the same function `ggml_gelu_erf` calls, on the same arguments, in the same
    /// order. A block of the buffer per core keeps a prefill's three million activations
    /// off one thread; a decode step's few thousand stay on the calling one.
    static func geluErf(_ x: UnsafeMutablePointer<Float>, count: Int) {
        let blockSize = 8192
        let blocks = (count + blockSize - 1) / blockSize
        guard blocks > 1 else {
            geluErf(x, from: 0, to: count)
            return
        }
        DispatchQueue.concurrentPerform(iterations: blocks) { block in
            let first = block * blockSize
            geluErf(x, from: first, to: min(first + blockSize, count))
        }
    }

    private static func geluErf(_ x: UnsafeMutablePointer<Float>, from first: Int, to last: Int) {
        let inverseRootTwo = Float(1 / 2.0.squareRoot())
        for index in first..<last {
            let value = x[index]
            x[index] = 0.5 * value * (1 + erff(value * inverseRootTwo))
        }
    }

    /// `y += x`, the residual add.
    static func add(_ y: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, count: Int) {
        vDSP_vadd(y, 1, x, 1, y, 1, vDSP_Length(count))
    }

    /// Softmax over each row of `columns`, in place, in `ggml_soft_max_ext`'s order:
    /// scale, add the mask, then normalise.
    ///
    /// `mask` is row-major `[rows][columns]` of 0 or -infinity. A masked entry comes out
    /// exactly zero because `exp(-infinity)` is zero, and no row can be entirely masked
    /// here -- a query position is always allowed to attend to itself -- so the maximum
    /// subtracted is always finite.
    static func softmaxRows(
        _ s: UnsafeMutablePointer<Float>, rows: Int, columns: Int, scale: Float,
        mask: UnsafePointer<Float>?
    ) {
        var factor = scale
        var elements = Int32(columns)
        for row in 0..<rows {
            let values = s + row * columns
            vDSP_vsmul(values, 1, &factor, values, 1, vDSP_Length(columns))
            if let mask {
                vDSP_vadd(values, 1, mask + row * columns, 1, values, 1, vDSP_Length(columns))
            }

            var highest: Float = 0
            vDSP_maxv(values, 1, &highest, vDSP_Length(columns))
            var negatedHighest = -highest
            vDSP_vsadd(values, 1, &negatedHighest, values, 1, vDSP_Length(columns))
            vvexpf(values, values, &elements)

            var total: Float = 0
            vDSP_sve(values, 1, &total, vDSP_Length(columns))
            var inverse = 1 / total
            vDSP_vsmul(values, 1, &inverse, values, 1, vDSP_Length(columns))
        }
    }

    /// The performance-core count, which is what a forward pass should be spread over:
    /// handing the efficiency cores an equal share of a memory-bound GEMV leaves the whole
    /// pass waiting on them. Falls back to every logical core where the key is absent.
    static let threadCount: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return Int(cores)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }()
}
