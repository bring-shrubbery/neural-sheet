// The kernels are checked against a scalar reference written out in `Double`, because
// only an independent formula can tell a correct layer norm from one that divides by
// n - 1, or the exact erf GELU from the tanh approximation the reference deliberately
// avoids. The data is pseudo-random rather than hand-picked so that a kernel cannot
// pass by accident on a symmetric input.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// A linear congruential generator, so every kernel test runs on the same numbers on
/// every machine without carrying a fixture. Shared with `CPUMatmulTests` and
/// `CPUAttentionTests`.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next value in -1 ..< 1. An LCG's low bits are famously poor, so this takes
    /// the top twenty-four.
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(UInt32(truncatingIfNeeded: state >> 40)) / Float(1 << 23) - 1
    }

    /// The next value in `range`.
    mutating func next(in range: ClosedRange<Float>) -> Float {
        let unit = (next() + 1) / 2
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// `count` values in -1 ..< 1.
    mutating func values(_ count: Int) -> [Float] {
        (0..<count).map { _ in next() }
    }
}

/// Copies `values` into a fresh allocation the caller owns, so a kernel can be handed
/// the raw pointers it takes without a stack of `withUnsafeBufferPointer` nesting.
func allocate(_ values: [Float]) -> UnsafeMutablePointer<Float> {
    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
    for index in values.indices {
        pointer[index] = values[index]
    }
    return pointer
}

@Test func layerNormNormalisesEachRowWithThePopulationVariance() {
    var rng = SeededRandom(seed: 1)
    let rows = 3
    let dim = 64
    let eps: Float = 1e-5
    let input = rng.values(rows * dim)
    let weight = rng.values(dim)
    let bias = rng.values(dim)

    let x = allocate(input)
    let w = allocate(weight)
    let b = allocate(bias)
    let out = allocate([Float](repeating: .nan, count: rows * dim))
    defer {
        x.deallocate()
        w.deallocate()
        b.deallocate()
        out.deallocate()
    }

    CPUKernels.layerNorm(x, rows: rows, dim: dim, weight: w, bias: b, eps: eps, out: out)

    for row in 0..<rows {
        let values = (0..<dim).map { Double(input[row * dim + $0]) }
        let mean = values.reduce(0, +) / Double(dim)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(dim)
        let inverse = 1 / (variance + Double(eps)).squareRoot()
        for column in 0..<dim {
            let expected = (values[column] - mean) * inverse * Double(weight[column]) + Double(bias[column])
            #expect(abs(Double(out[row * dim + column]) - expected) < 1e-5)
        }
    }
}

@Test func geluErfMatchesTheExactErfFormula() {
    var rng = SeededRandom(seed: 2)
    let count = 1000
    let input = (0..<count).map { _ in rng.next(in: -6...6) }

    let x = allocate(input)
    defer { x.deallocate() }

    CPUKernels.geluErf(x, count: count)

    for index in 0..<count {
        let value = Double(input[index])
        let expected = 0.5 * value * (1 + erf(value / 2.0.squareRoot()))
        #expect(abs(Double(x[index]) - expected) < 1e-6)
    }
}

@Test func geluErfHoldsItsFixedPoints() {
    let x = allocate([0, 3])
    defer { x.deallocate() }

    CPUKernels.geluErf(x, count: 2)

    #expect(x[0] == 0)
    #expect(abs(x[1] - 2.99595) < 1e-5)
}

@Test func geluErfIsNotTheTanhApproximation() {
    let x = allocate([-2.5])
    defer { x.deallocate() }

    CPUKernels.geluErf(x, count: 1)

    // ggml_gelu is the tanh form and ggml_gelu_erf is not. The two differ here by far
    // more than the tolerance the formula test allows, and the gap compounds over the
    // layers, so this pins which of the two we implement.
    let value = -2.5
    let inner = (2 / Double.pi).squareRoot() * (value + 0.044715 * value * value * value)
    let tanhForm = 0.5 * value * (1 + tanh(inner))
    #expect(abs(Double(x[0]) - tanhForm) > 1e-4)
}

@Test func addAccumulatesIntoTheDestination() {
    var rng = SeededRandom(seed: 3)
    let count = 37
    let left = rng.values(count)
    let right = rng.values(count)

    let y = allocate(left)
    let x = allocate(right)
    defer {
        y.deallocate()
        x.deallocate()
    }

    CPUKernels.add(y, x, count: count)

    for index in 0..<count {
        #expect(y[index] == left[index] + right[index])
    }
}

@Test func softmaxRowsScalesThenMasksThenNormalises() {
    var rng = SeededRandom(seed: 4)
    let rows = 2
    let columns = 7
    let scale: Float = 0.125
    let input = rng.values(rows * columns)
    var mask = [Float](repeating: 0, count: rows * columns)
    for column in 4..<columns {
        mask[column] = -.infinity
    }

    let s = allocate(input)
    let m = allocate(mask)
    defer {
        s.deallocate()
        m.deallocate()
    }

    CPUKernels.softmaxRows(s, rows: rows, columns: columns, scale: scale, mask: m)

    for row in 0..<rows {
        let scores = (0..<columns).map {
            Double(input[row * columns + $0]) * Double(scale) + Double(mask[row * columns + $0])
        }
        let highest = scores.max() ?? 0
        let exponentials = scores.map { $0 == -.infinity ? 0 : exp($0 - highest) }
        let total = exponentials.reduce(0, +)

        var sum = 0.0
        for column in 0..<columns {
            let expected = exponentials[column] / total
            let produced = Double(s[row * columns + column])
            if mask[row * columns + column] == -.infinity {
                #expect(produced == 0)
            }
            #expect(abs(produced - expected) < 1e-6)
            sum += produced
        }
        #expect(abs(sum - 1) < 1e-6)
    }
}

@Test func softmaxRowsWithoutAMaskNormalisesEveryColumn() {
    var rng = SeededRandom(seed: 5)
    let columns = 7
    let input = rng.values(columns)

    let s = allocate(input)
    defer { s.deallocate() }

    CPUKernels.softmaxRows(s, rows: 1, columns: columns, scale: 1, mask: nil)

    let exponentials = input.map { exp(Double($0) - Double(input.max() ?? 0)) }
    let total = exponentials.reduce(0, +)
    for column in 0..<columns {
        #expect(abs(Double(s[column]) - exponentials[column] / total) < 1e-6)
    }
}

@Test func threadCountIsAtLeastOneAndNoMoreThanTheMachine() {
    #expect(CPUKernels.threadCount >= 1)
    #expect(CPUKernels.threadCount <= ProcessInfo.processInfo.processorCount)
}
