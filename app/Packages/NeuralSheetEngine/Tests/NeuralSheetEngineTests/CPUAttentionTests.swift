// Attention is the one kernel where a plausible-looking mistake -- an off-by-one in the
// causal bound, a head read at the wrong column offset, a cache row past the filled
// region -- still produces finite, reasonable numbers, so the reference here is a
// literal transcription of the formula in `Double`, and the second test pins the
// degenerate case where the answer is a value rather than a formula.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// The attention of §4 of the design, spelled out: per head, scores against every cache
/// row up to and including the query's own position, softmax, then the weighted sum of
/// the value rows.
private func referenceAttend(
    q: [Float], kCache: [Float], vCache: [Float],
    nNew: Int, nPast: Int, nHead: Int, headDim: Int, scale: Float
) -> [Double] {
    let dim = nHead * headDim
    var out = [Double](repeating: 0, count: nNew * dim)
    for head in 0..<nHead {
        for row in 0..<nNew {
            let allowed = nPast + row + 1
            var scores = [Double]()
            for key in 0..<allowed {
                var dot = 0.0
                for index in 0..<headDim {
                    dot += Double(q[row * dim + head * headDim + index])
                        * Double(kCache[key * dim + head * headDim + index])
                }
                scores.append(dot * Double(scale))
            }
            let highest = scores.max() ?? 0
            let exponentials = scores.map { exp($0 - highest) }
            let total = exponentials.reduce(0, +)
            for index in 0..<headDim {
                var sum = 0.0
                for key in 0..<allowed {
                    sum += exponentials[key] / total * Double(vCache[key * dim + head * headDim + index])
                }
                out[row * dim + head * headDim + index] = sum
            }
        }
    }
    return out
}

@Test func attendMatchesTheReferenceOverAFilledCache() {
    var rng = SeededRandom(seed: 21)
    let nHead = 2
    let headDim = 4
    let dim = nHead * headDim
    let nPast = 3
    let nNew = 2
    let nCtx = 8
    let scale: Float = 0.5

    let queries = rng.values(nNew * dim)
    var keys = rng.values(nCtx * dim)
    var values = rng.values(nCtx * dim)
    // Rows past the filled region must not be read, so fill them with values that would
    // wreck the result if they were.
    for index in ((nPast + nNew) * dim)..<(nCtx * dim) {
        keys[index] = 1e6
        values[index] = 1e6
    }

    // The backend hands over the q third of a `[nNew][3 · dim]` projection, so the queries
    // sit at the head of a wider row whose remainder holds the keys and values of the same
    // position. Those columns must not be read either, so they are poisoned the same way.
    let qRowStride = 3 * dim
    var padded = [Float](repeating: 1e6, count: nNew * qRowStride)
    for row in 0..<nNew {
        for column in 0..<dim {
            padded[row * qRowStride + column] = queries[row * dim + column]
        }
    }

    let q = allocate(padded)
    let k = allocate(keys)
    let v = allocate(values)
    let scores = allocate([Float](repeating: .nan, count: nHead * nNew * (nPast + nNew)))
    let out = allocate([Float](repeating: .nan, count: nNew * dim))
    defer {
        q.deallocate()
        k.deallocate()
        v.deallocate()
        scores.deallocate()
        out.deallocate()
    }

    CPUAttention.attend(
        q: q, qRowStride: qRowStride, kCache: k, vCache: v, nNew: nNew, nPast: nPast,
        nHead: nHead, headDim: headDim, scale: scale, scores: scores, out: out)

    let reference = referenceAttend(
        q: queries, kCache: keys, vCache: values,
        nNew: nNew, nPast: nPast, nHead: nHead, headDim: headDim, scale: scale)
    for index in reference.indices {
        #expect(abs(Double(out[index]) - reference[index]) < 1e-6)
    }
}

@Test func attendOnTheFirstRowAloneReturnsItsOwnValue() {
    var rng = SeededRandom(seed: 22)
    let nHead = 2
    let headDim = 4
    let dim = nHead * headDim
    let nCtx = 8

    let queries = rng.values(dim)
    let keys = rng.values(nCtx * dim)
    let values = rng.values(nCtx * dim)

    let q = allocate(queries)
    let k = allocate(keys)
    let v = allocate(values)
    let scores = allocate([Float](repeating: .nan, count: nHead))
    let out = allocate([Float](repeating: .nan, count: dim))
    defer {
        q.deallocate()
        k.deallocate()
        v.deallocate()
        scores.deallocate()
        out.deallocate()
    }

    CPUAttention.attend(
        q: q, qRowStride: dim, kCache: k, vCache: v, nNew: 1, nPast: 0, nHead: nHead,
        headDim: headDim, scale: 0.5, scores: scores, out: out)

    // One row attending only to itself gives a probability of exactly one, so the output
    // is the first value row unchanged.
    for index in 0..<dim {
        #expect(out[index] == values[index])
    }
}
