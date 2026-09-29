// The matmul has two code paths for the same arithmetic -- a hand-written SIMD GEMV for
// one row and cblas for several -- so both are checked against the same `Double`
// reference on the same weights. The F16 weights are rounded through `Float16` before
// the reference sums them, because the rounding is part of the contract: the kernel is
// exact with respect to the stored weight, not to the float it came from.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// `out[r][o] = Σ_i W[o][i] · x[r][i]`, accumulated in `Double`.
private func referenceMatmul(
    weights: [Float], outFeatures: Int, inFeatures: Int, input: [Float], rows: Int
) -> [Double] {
    var out = [Double](repeating: 0, count: rows * outFeatures)
    for row in 0..<rows {
        for feature in 0..<outFeatures {
            var sum = 0.0
            for index in 0..<inFeatures {
                sum += Double(weights[feature * inFeatures + index]) * Double(input[row * inFeatures + index])
            }
            out[row * outFeatures + feature] = sum
        }
    }
    return out
}

/// The tolerance the brief gives as "1e-4 × scale": the scale of the numbers being
/// compared, which for a dot product of random values is the largest reference
/// magnitude, never letting it shrink the tolerance below 1e-4 itself.
private func tolerance(for reference: [Double]) -> Double {
    1e-4 * max(1, reference.map { abs($0) }.max() ?? 1)
}

/// Random weights rounded through `Float16`, plus the `Float` values they round to, so
/// the reference sums exactly what the kernel reads.
private func halfWeights(_ rng: inout SeededRandom, count: Int) -> (halves: [Float16], floats: [Float]) {
    let halves = (0..<count).map { _ in Float16(rng.next()) }
    return (halves, halves.map { Float($0) })
}

private func checkMatmulF16(outFeatures: Int, inFeatures: Int, rows: Int, seed: UInt64) {
    var rng = SeededRandom(seed: seed)
    let (halves, floats) = halfWeights(&rng, count: outFeatures * inFeatures)
    let input = rng.values(rows * inFeatures)

    let weights = UnsafeMutablePointer<Float16>.allocate(capacity: halves.count)
    for index in halves.indices {
        weights[index] = halves[index]
    }
    let x = allocate(input)
    let out = allocate([Float](repeating: .nan, count: rows * outFeatures))
    let scratch = allocate([Float](repeating: .nan, count: outFeatures * inFeatures))
    defer {
        weights.deallocate()
        x.deallocate()
        out.deallocate()
        scratch.deallocate()
    }

    CPUMatmul.matmulF16(
        weights: weights, outFeatures: outFeatures, inFeatures: inFeatures,
        input: x, rows: rows, output: out, scratch: scratch)

    let reference = referenceMatmul(
        weights: floats, outFeatures: outFeatures, inFeatures: inFeatures, input: input, rows: rows)
    let allowed = tolerance(for: reference)
    for index in reference.indices {
        #expect(abs(Double(out[index]) - reference[index]) < allowed)
    }
}

@Test func matmulF16GemvMatchesTheReference() {
    checkMatmulF16(outFeatures: 48, inFeatures: 96, rows: 1, seed: 11)
}

@Test func matmulF16GemmMatchesTheReference() {
    checkMatmulF16(outFeatures: 48, inFeatures: 96, rows: 5, seed: 12)
}

@Test func matmulF16GemvHandlesAnInFeatureTail() {
    // The real checkpoints only ever have a multiple of 32 here, but the GEMV's scalar
    // tail has to be right or a future shape would fail silently.
    checkMatmulF16(outFeatures: 48, inFeatures: 100, rows: 1, seed: 13)
}

@Test func matmulF32MatchesTheReference() {
    var rng = SeededRandom(seed: 14)
    let outFeatures = 40
    let inFeatures = 24
    let rows = 3
    let weights = rng.values(outFeatures * inFeatures)
    let input = rng.values(rows * inFeatures)

    let w = allocate(weights)
    let x = allocate(input)
    let out = allocate([Float](repeating: .nan, count: rows * outFeatures))
    defer {
        w.deallocate()
        x.deallocate()
        out.deallocate()
    }

    CPUMatmul.matmulF32(
        weights: w, outFeatures: outFeatures, inFeatures: inFeatures,
        input: x, rows: rows, output: out)

    let reference = referenceMatmul(
        weights: weights, outFeatures: outFeatures, inFeatures: inFeatures, input: input, rows: rows)
    let allowed = tolerance(for: reference)
    for index in reference.indices {
        #expect(abs(Double(out[index]) - reference[index]) < allowed)
    }
}
