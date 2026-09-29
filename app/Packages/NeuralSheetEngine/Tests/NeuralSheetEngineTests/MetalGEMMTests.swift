// `matmul_tiled_f16` on its own, at shapes the checkpoints do not have.
//
// The oracle suites exercise the prefill GEMM only through the two checkpoints, whose every
// weight has an `outFeatures` that is a multiple of 64 and an `inFeatures` that is a multiple
// of 16. So the kernel's column bound, its K bound and its partial-row store never run there,
// and those suites skip silently on a machine with no checkpoint. This one needs a Metal
// device and nothing else, and it feeds the kernel the awkward shapes: a column count that
// leaves a ragged tile, a K that does not fill a staged pass, fewer rows than one tile, and
// the smallest dispatch there is.
//
// The reference is a Swift loop in the kernel's own order -- straight up K, one fused
// multiply-add at a time -- so the comparison is for equal bits and not for a tolerance. That
// is what the kernel does: a staged pass covers k in ascending order and the passes run in
// ascending order too, which makes the whole sum sequential. A tolerance here would hide the
// one thing worth catching, a tile that sums the wrong elements.
//
// Four of the kernel's six bounds are observable through its output and each was checked by
// removing it and watching this suite fail: the row and column bounds on the store (which
// then writes into the sentinel past the result) and the two K bounds on the staging (which
// then read the NaN past each operand). The row and column bounds on the *staging* are not
// observable, because what they would stage only ever lands in an accumulator the store
// discards; they are there to keep the kernel from reading past a tensor at all, and nothing
// here can see that.

import Foundation
import Metal
import Testing

@testable import NeuralSheetEngine

@Suite(.serialized) struct MetalGEMMTests {
    /// Written into the output buffer past the last element the kernel may touch, so that a
    /// tile storing outside its block is a failure rather than a silent overwrite of memory
    /// nothing reads. Not zero and not a plausible product: any arithmetic landing here
    /// changes it.
    private static let sentinel = Float(-12345.678)

    /// Enough slack past `rows * outFeatures` for a whole tile to run off the end into it,
    /// and past each operand for a staged pass to reach beyond K.
    private static let padding = 64 * 64

    /// Written past the end of both operands. The kernel stages an exact zero for anything
    /// outside the matrix rather than reading it, so a correct pass never touches this; a pass
    /// that drops one of its bounds reads a NaN, and a NaN survives `fma` even against a zero
    /// from the other operand -- which is what makes the two K bounds testable one at a time.
    /// They are not otherwise: with either one in place the other's out-of-range element is
    /// multiplied by a staged zero, so dropping just one is invisible against real data.
    private static let poison = Float.nan

    /// The shapes. Together they cover a tile that fits exactly, a ragged column tile, a K
    /// shorter than one staged pass, a K that is ragged rather than short, fewer rows than a
    /// tile, and a single row -- which `matrixProduct` sends to `matvec_f16` instead, and
    /// which at one input feature is a single product and so still exact.
    private static let shapes: [(rows: Int, outFeatures: Int, inFeatures: Int)] = [
        (rows: 64, outFeatures: 64, inFeatures: 16),
        (rows: 3, outFeatures: 1393, inFeatures: 31),
        (rows: 2, outFeatures: 65, inFeatures: 17),
        (rows: 70, outFeatures: 129, inFeatures: 48),
        (rows: 130, outFeatures: 1393, inFeatures: 31),
        (rows: 65, outFeatures: 64, inFeatures: 1),
        (rows: 1, outFeatures: 1, inFeatures: 1),
    ]

    /// The engine's usual bring-up, without a checkpoint: the library is a string, so the
    /// kernels can be compiled and dispatched on any device. Nil on a machine with no GPU,
    /// which skips the suite the way the oracle suites skip without weights.
    private func setUp() throws -> (device: MTLDevice, queue: MTLCommandQueue, kernels: MetalKernels)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }

        let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)
        return (device, queue, try MetalKernels(device: device, library: library))
    }

    /// Deterministic operands with both signs and a spread of magnitudes, and values that are
    /// exact in F16 so that the reference and the kernel start from the same bits.
    private func weightValues(count: Int) -> [Float16] {
        (0 ..< count).map { Float16(Float(($0 * 7) % 31 - 15) * 0.0625) }
    }

    private func inputValues(count: Int) -> [Float] {
        (0 ..< count).map { Float(($0 * 11) % 23 - 11) * 0.125 }
    }

    /// `out[r][o] = sum_i W[o][i] . x[r][i]`, summed up K in order with a fused multiply-add,
    /// which is what the kernel's staged passes add up to.
    private func reference(
        weights: [Float16], input: [Float], rows: Int, outFeatures: Int, inFeatures: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: rows * outFeatures)

        for row in 0 ..< rows {
            for feature in 0 ..< outFeatures {
                var total = Float(0)

                for index in 0 ..< inFeatures {
                    total = total.addingProduct(
                        Float(weights[feature * inFeatures + index]), input[row * inFeatures + index])
                }

                out[row * outFeatures + feature] = total
            }
        }

        return out
    }

    @Test func theProductIsExactAtEveryShape() throws {
        guard let (device, queue, kernels) = try setUp() else { return }

        for shape in MetalGEMMTests.shapes {
            let weights = weightValues(count: shape.outFeatures * shape.inFeatures)
            let input = inputValues(count: shape.rows * shape.inFeatures)
            let expected = reference(
                weights: weights, input: input,
                rows: shape.rows, outFeatures: shape.outFeatures, inFeatures: shape.inFeatures)

            // The operands carry a NaN tail and the output a sentinel one, so that a read or a
            // store outside the matrix shows up in the result instead of quietly touching
            // memory nothing checks.
            let paddedWeights = weights + [Float16](
                repeating: Float16(MetalGEMMTests.poison), count: MetalGEMMTests.padding)
            let paddedInput = input + [Float](
                repeating: MetalGEMMTests.poison, count: MetalGEMMTests.padding)

            guard
                let weightsBuffer = device.makeBuffer(
                    bytes: paddedWeights, length: paddedWeights.count * 2, options: .storageModeShared),
                let inputBuffer = device.makeBuffer(
                    bytes: paddedInput, length: paddedInput.count * 4, options: .storageModeShared),
                let outputBuffer = device.makeBuffer(
                    length: (expected.count + MetalGEMMTests.padding) * 4, options: .storageModeShared)
            else {
                Issue.record("the Metal device would not make the buffers for \(shape)")
                return
            }

            let contents = outputBuffer.contents().assumingMemoryBound(to: Float.self)
            let total = expected.count + MetalGEMMTests.padding

            for index in 0 ..< total {
                contents[index] = MetalGEMMTests.sentinel
            }

            guard let commands = queue.makeCommandBuffer(),
                let encoder = commands.makeComputeCommandEncoder()
            else {
                Issue.record("the Metal queue would not make a command buffer for \(shape)")
                return
            }

            kernels.matrixProduct(
                encoder, weights: weightsBuffer, weightsOffset: 0, input: inputBuffer, inputOffset: 0,
                output: outputBuffer, outputOffset: 0,
                outFeatures: shape.outFeatures, inFeatures: shape.inFeatures, rows: shape.rows)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()

            #expect(commands.error == nil, "\(shape) failed on the GPU")

            let got = Array(UnsafeBufferPointer(start: contents, count: total))
            let product = Array(got[0 ..< expected.count])

            #expect(product == expected, "\(shape) differs from the reference\(firstGap(product, expected))")

            let overrun = got[expected.count ..< total].filter { $0 != MetalGEMMTests.sentinel }
            #expect(overrun.isEmpty, "\(shape) wrote \(overrun.count) values past its output")
        }
    }

    /// Where two results first part company, for a failure message that names an element
    /// rather than leaving a reader to diff a million floats.
    private func firstGap(_ got: [Float], _ expected: [Float]) -> String {
        for (index, pair) in zip(got, expected).enumerated() where pair.0 != pair.1 {
            return ": at \(index), \(pair.0) against \(pair.1)"
        }

        return ""
    }

    /// The tile the kernel was compiled with is the tile the dispatch uses. They are one
    /// definition now, so this is a guard against someone splitting them again rather than a
    /// check on arithmetic -- and against a tile whose threads do not divide it evenly, which
    /// would leave part of every block unwritten.
    @Test func theTileAndTheDispatchAgree() {
        let tile = MetalShaderSource.gemmTile

        #expect(MetalKernels.gemmThreads.width == tile.threads)
        #expect(MetalKernels.gemmThreads.height == 1)
        #expect(MetalKernels.gemmThreads.depth == 1)
        #expect(tile.rows % tile.perThread == 0, "the tile's rows are not a whole number of squares")
        #expect(tile.features % tile.perThread == 0, "the tile's features are not a whole number of squares")
        #expect(
            MetalShaderSource.source.contains("#define GEMM_TM \(tile.rows)"),
            "the shader source was not built from the tile")
        #expect(
            MetalShaderSource.source.contains("#define GEMM_TK \(tile.depth)"),
            "the shader source was not built from the tile")
    }
}
