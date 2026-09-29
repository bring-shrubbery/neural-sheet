// Numeric comparisons the oracle tests share. Two arrays of logits or of mel
// frames are never bit-identical across two matmul libraries, so every oracle
// test states a tolerance relative to the tensor's own scale plus, where the
// decision the engine makes from the values matters more than the values, the
// cosine and the argmax that decision rests on.

import Foundation

enum Compare {
    /// The largest element-wise gap. Arrays of different lengths compare over the
    /// shorter prefix; a test asserts the lengths separately, so this never hides a
    /// shape bug behind a crash.
    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    }

    /// The cosine similarity in `Double`: an F32 dot product over 384 000 values
    /// loses enough precision to move the fifth decimal, which is exactly where the
    /// conditioning tolerance sits.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0

        for (left, right) in zip(a, b) {
            dot += Double(left) * Double(right)
            normA += Double(left) * Double(left)
            normB += Double(right) * Double(right)
        }

        guard normA > 0, normB > 0 else { return 0 }

        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// The tensor's scale, which is what a relative tolerance is measured against.
    static func scale(_ a: [Float]) -> Float {
        a.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// The index of the largest value, or -1 for an empty array. Ties go to the
    /// first, as `ggml_argmax` and the engine's own greedy step both do.
    static func argmax(_ a: [Float]) -> Int {
        var best = -1
        var bestValue = -Float.infinity

        for (index, value) in a.enumerated() where value > bestValue {
            bestValue = value
            best = index
        }

        return best
    }

    /// The gap between the largest and second-largest value: how much numeric drift
    /// an argmax can absorb before it picks a different token.
    static func topTwoMargin(_ a: [Float]) -> Float {
        var first = -Float.infinity
        var second = -Float.infinity

        for value in a {
            if value > first {
                second = first
                first = value
            } else if value > second {
                second = value
            }
        }

        return first - second
    }
}
