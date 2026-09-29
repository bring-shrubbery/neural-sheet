// Ported from muscriptor.cpp's cpp/src/model.cpp (`buildPositionTable`).

import Foundation

/// The sinusoidal position embeddings, built once at load.
///
/// Two details differ from the textbook sinusoid and both matter downstream: the
/// exponent's denominator is `half - 1`, not `half`, and the halves are ordered
/// cosine-then-sine rather than the usual sine-then-cosine.
///
/// The table is F32 even when the transformer runs in F16, because F16 cannot represent
/// odd integers above 2048 and adjacent positions past that would collapse onto the
/// same embedding.
struct PositionTable: Sendable {
    let count: Int
    let dim: Int

    /// `[count][dim]`, row-major.
    let values: [Float]

    init(count: Int, dim: Int, maxPeriod: Float) throws {
        guard dim % 2 == 0 else {
            throw TranscriberError.unsupportedArchitecture("model dimension must be even for sinusoidal positions")
        }

        self.count = count
        self.dim = dim
        let half = dim / 2
        var table = [Float](repeating: 0, count: count * dim)

        // Every step is in Float, including the exponent and `powf`, so the table is bit
        // for bit the one the C++ builds. Computing a phase in Double and rounding would
        // differ in the last place and the logits would drift with it.
        table.withUnsafeMutableBufferPointer { row in
            for position in 0 ..< count {
                let base = position * dim

                for index in 0 ..< half {
                    let exponent = Float(index) / Float(half - 1)
                    let phase = Float(position) / powf(maxPeriod, exponent)
                    row[base + index] = cosf(phase)
                    row[base + half + index] = sinf(phase)
                }
            }
        }

        values = table
    }

    /// `n` consecutive rows, as a slice of the flat table rather than a copy: the prefix
    /// builder adds them to the embeddings a chunk at a time.
    func rows(from start: Int, count n: Int) -> ArraySlice<Float> {
        precondition(
            start >= 0 && n >= 0 && start + n <= count, "position rows \(start)..<\(start + n) are not in the table")
        return values[(start * dim) ..< ((start + n) * dim)]
    }
}
