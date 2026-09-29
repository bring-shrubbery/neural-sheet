// The vocabulary is pure arithmetic, so the reference dump in tables.json can
// check it exhaustively where it matters and by spot check everywhere else.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// The fixture names the event kinds the way the reference's Python does: the three
/// specials in capitals, the ranges in lower case.
private func eventType(named name: String) -> EventType? {
    switch name {
    case "PAD": return .pad
    case "EOS": return .eos
    case "UNK": return .unk
    case "shift": return .shift
    case "pitch": return .pitch
    case "velocity": return .velocity
    case "tie": return .tie
    case "program": return .program
    case "drum": return .drum
    default: return nil
    }
}

private func tables() throws -> [String: Any] {
    try #require(try Fixtures.json("vectors/tables.json") as? [String: Any])
}

@Test func rangesMatchTheReferenceTable() throws {
    let vocab = try #require(try tables()["vocab"] as? [String: Any])
    let ranges = try #require(vocab["ranges"] as? [String: [Int]])

    #expect(ranges["shift"] == [Int(Vocabulary.shiftFirst), Int(Vocabulary.shiftFirst + Vocabulary.shiftCount - 1)])
    #expect(ranges["pitch"] == [Int(Vocabulary.pitchFirst), Int(Vocabulary.pitchFirst + Vocabulary.pitchCount - 1)])
    #expect(ranges["velocity"] == [1132, 1133])
    #expect(ranges["tie"] == [1134, 1134])
    #expect(ranges["program"] == [1135, 1264])
    #expect(ranges["drum"] == [1265, 1392])
    #expect(vocab["num_tokens"] as? Int == Int(Vocabulary.numTokens))
    #expect(vocab["eos_id"] as? Int == Int(Vocabulary.eosID))
    #expect(Vocabulary.numTokens == 1393)
    #expect(Vocabulary.frameRate == 100)
}

@Test func spotChecksDecode() throws {
    let vocab = try #require(try tables()["vocab"] as? [String: Any])
    let spotChecks = try #require(vocab["spot_check"] as? [[Any]])
    #expect(!spotChecks.isEmpty)

    for triple in spotChecks {
        let id = try #require(triple[0] as? Int)
        let name = try #require(triple[1] as? String)
        let type = try #require(eventType(named: name))
        let value = Int32(try #require(triple[2] as? Int))

        #expect(Vocabulary.event(for: Int32(id)) == TokenEvent(type: type, value: value))
        #expect(Vocabulary.token(for: type, value: value) == Int32(id))
    }
}

@Test func outOfRangeIdsAreUnknown() {
    #expect(Vocabulary.event(for: -1) == TokenEvent(type: .unk, value: 0))
    #expect(Vocabulary.event(for: Vocabulary.numTokens) == TokenEvent(type: .unk, value: 0))
    #expect(Vocabulary.token(for: .pitch, value: 128) == -1)
    #expect(Vocabulary.token(for: .pitch, value: -1) == -1)
    #expect(Vocabulary.token(for: .shift, value: Vocabulary.maxShiftSteps) == -1)
}

@Test func tieSectionsMatchTheReference() throws {
    let cases = try #require(try tables()["tie_section_token_ids"] as? [[String: Any]])
    #expect(!cases.isEmpty)

    for one in cases {
        let openKeys = try #require(one["open_keys"] as? [[Int]]).map { NoteKey(program: $0[0], pitch: $0[1]) }
        let expected = try #require(one["token_ids"] as? [Int]).map(Int32.init)

        #expect(Vocabulary.tieSectionTokenIDs(openKeys: openKeys) == expected)
        #expect(Vocabulary.tieSectionTokenIDs(openKeys: openKeys.reversed()) == expected,
                "the prologue is sorted, so the caller's order must not matter")
    }
}
