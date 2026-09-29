// The position table is the one place where the reference's formula differs from
// the textbook sinusoid in two ways at once, so it is checked twice: against an
// independent double-precision evaluation of what the C++ says it computes, and
// against the C++'s own dump of the first rows.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// The same formula in `Double`, written from the C++ rather than from the Swift:
/// the exponent's denominator is `half - 1`, and the cosine half comes first.
private func referenceTable(count: Int, dim: Int, maxPeriod: Double) -> [Double] {
    let half = dim / 2
    var table = [Double](repeating: 0, count: count * dim)

    for pos in 0 ..< count {
        for i in 0 ..< half {
            let exponent = Double(i) / Double(half - 1)
            let phase = Double(pos) / pow(maxPeriod, exponent)
            table[pos * dim + i] = cos(phase)
            table[pos * dim + half + i] = sin(phase)
        }
    }

    return table
}

@Suite struct PositionTableTests {
    @Test func matchesADoublePrecisionEvaluation() throws {
        let table = try PositionTable(count: 8, dim: 768, maxPeriod: 10000)
        #expect(table.count == 8)
        #expect(table.dim == 768)
        #expect(table.values.count == 8 * 768)

        let reference = referenceTable(count: 8, dim: 768, maxPeriod: 10000)
        let worst = zip(table.values, reference).map { abs(Double($0) - $1) }.max() ?? 0
        #expect(worst < 1e-5, "worst deviation \(worst)")
    }

    @Test func requiresAnEvenDimension() {
        let error = #expect(throws: TranscriberError.self) { try PositionTable(count: 4, dim: 7, maxPeriod: 10000) }

        if case .unsupportedArchitecture = error {} else {
            Issue.record("expected .unsupportedArchitecture, got \(String(describing: error))")
        }
    }

    @Test func rowsAreContiguousSlicesOfTheTable() throws {
        let table = try PositionTable(count: 8, dim: 768, maxPeriod: 10000)
        let rows = table.rows(from: 2, count: 3)
        #expect(rows.count == 3 * 768)
        #expect(Array(rows) == Array(table.values[(2 * 768) ..< (5 * 768)]))
    }

    @Test func matchesTheReferenceDump() throws {
        // The dump is committed, so it is required: nothing here needs a checkpoint, and
        // there is no machine this test may skip on.
        let dump = try Fixtures.floats("oracle/small-cpu/positions.f32")

        let rows = dump.count / 768
        #expect(rows == 8)

        let table = try PositionTable(count: rows, dim: 768, maxPeriod: 10000)
        let worst = zip(table.values, dump).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-6, "worst deviation \(worst)")
    }
}
