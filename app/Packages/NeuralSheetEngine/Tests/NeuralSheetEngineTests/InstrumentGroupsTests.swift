// The instrument table is generated from CPython set ordering upstream, so it is
// transcribed rather than derived. tables.json is the only thing that can catch a
// transposed digit in it.

import Foundation
import Testing

@testable import NeuralSheetEngine

private func instrumentGroupsTable() throws -> [String: Any] {
    let tables = try #require(try Fixtures.json("vectors/tables.json") as? [String: Any])
    return try #require(tables["instrument_groups"] as? [String: Any])
}

@Test func everyGroupsRepresentativeIsItsFirstProgram() throws {
    let map = try #require(try instrumentGroupsTable()["group_program_map"] as? [String: [Int]])

    #expect(map.count == 66)
    #expect(InstrumentGroups.numGroups == map.count)

    for (key, programs) in map {
        let groupID = try #require(Int(key))
        #expect(InstrumentGroups.representativeProgram(groupID: groupID) == programs[0])

        // The representative is the only program the model emits for the group, so
        // every program of the group must answer that group id.
        #expect(InstrumentGroups.groupID(forProgram: programs[0]) == groupID)
    }

    #expect(InstrumentGroups.representativeProgram(groupID: -1) == -1)
    #expect(InstrumentGroups.representativeProgram(groupID: 66) == -1)
}

@Test func namesMatchTheTable() throws {
    let names = try #require(try instrumentGroupsTable()["names"] as? [String: Int])

    #expect(names.count == InstrumentGroups.maxSelectable)
    #expect(InstrumentGroups.maxSelectable == 35)

    for (name, groupID) in names {
        #expect(InstrumentGroups.name(forGroupID: groupID) == name)
        #expect(InstrumentGroups.group(forName: name) == InstrumentGroup(rawValue: Int32(groupID)))
        #expect(InstrumentGroup(rawValue: Int32(groupID))?.name == name)
    }

    for unnamed in [34, 35, 37, 65] {
        #expect(InstrumentGroups.name(forGroupID: unnamed) == nil, "group \(unnamed) has no name")
    }

    #expect(InstrumentGroups.name(forGroupID: 66) == nil)
    #expect(InstrumentGroups.group(forName: "harpsichord") == nil)
}

@Test func drumProgramIsTheReferences() throws {
    let table = try instrumentGroupsTable()

    #expect(table["drum_program"] as? Int == Note.drumProgram)
    #expect(Note.drumProgram == 128)
    #expect(Note.minimumDuration == 0.01)

    #expect(InstrumentGroup(program: 128) == .drums)
    #expect(InstrumentGroup(program: 96) == .drums, "the reference routes a decoded program 96 to drums")
    #expect(InstrumentGroup(program: 100) == nil, "group 34 has no name")
    #expect(InstrumentGroup(program: 33) == .electricBass)
    #expect(InstrumentGroup.drums.program == 128)
    #expect(InstrumentGroup.electricBass.program == 33)
}

@Test func forbiddenIdsMatchTheReference() throws {
    let tables = try #require(try Fixtures.json("vectors/tables.json") as? [String: Any])
    let cases = try #require(tables["forbidden_token_ids"] as? [[String: Any]])
    var checked = 0

    for one in cases {
        let names = try #require(one["instruments"] as? [String])

        // The empty selection is not a case the port can answer: the reference would
        // forbid every program and every drum, so `Transcriber` skips the mask instead.
        guard !names.isEmpty else { continue }

        let groups = try names.map { try #require(InstrumentGroups.group(forName: $0)) }
        let expected = try #require(one["token_ids"] as? [Int]).map(Int32.init)
        let forbidden = InstrumentGroups.forbiddenTokenIDs(groups)

        #expect(forbidden == expected.sorted())
        #expect(Set(forbidden) == Set(expected))
        #expect(forbidden.count == Set(forbidden).count, "the ids are unique")
        checked += 1
    }

    #expect(checked > 0)
}

@Test func conditioningRows() {
    #expect(InstrumentGroups.conditioningRows([]) == [InstrumentGroups.nullConditioningRow])
    #expect(InstrumentGroups.nullConditioningRow == 1)
    #expect(InstrumentGroups.conditioningRows([.electricBass, .drums]) == [10, 38])
    #expect(InstrumentGroups.conditioningRow(.acousticPiano) == 2)
}

@Test func allCasesAreInIdOrderAndCount35() {
    let ids = InstrumentGroup.allCases.map(\.rawValue)

    #expect(ids.count == 35)
    #expect(ids == ids.sorted())
    #expect(ids.first == 0)
    #expect(ids.last == 36)
}

@Test func labels() throws {
    let labels = try #require(try instrumentGroupsTable()["program_to_name"] as? [String: String])
    #expect(labels.count == 130)

    for (key, label) in labels {
        let program = try #require(Int(key))
        #expect(InstrumentGroup.label(forProgram: program) == label)
    }

    #expect(InstrumentGroup.label(forProgram: 33) == "electric_bass")
    #expect(InstrumentGroup.label(forProgram: 100) == "program_100")
    #expect(InstrumentGroup.label(forProgram: 128) == "drums")
}
