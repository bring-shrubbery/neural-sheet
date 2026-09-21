import Foundation
import Testing

@testable import NeuralSheetCore

/// A fresh directory under the system temp area. Never the user's real Library.
private func makeProjectTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func projectStateDefaultsMatchTheApp() {
    let state = ProjectState()

    #expect(state.formatVersion == ProjectState.currentFormatVersion)
    #expect(state.audioFileName == "")
    #expect(state.audioDisplayName == nil)
    #expect(state.selectedGroups.isEmpty)
    #expect(state.mixer.isEmpty)
    #expect(state.exportTempo == 120)
    #expect(state.gridOffsetSeconds == 0)
    #expect(state.gridDivision == .sixteenth)
    #expect(state.snapEnabled)
    #expect(state.targetProgram == nil)
    #expect(state.workspace == .transcribe)
    #expect(state.playheadSeconds == 0)
    #expect(state.playheadCentered)
    #expect(state.zoomLevel == 1)
    #expect(state.verticalZoom == -1)
}

@Test func projectStateRoundTripsThroughAFile() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")

    var state = ProjectState()
    state.audioFileName = "take.flac"
    state.audioDisplayName = "take"
    state.selectedGroups = [0, 36]
    state.mixer = [
        0: InstrumentChannelSettings(gainDb: -6, muted: true, soloed: false),
        33: InstrumentChannelSettings(gainDb: 1.5, muted: false, soloed: true),
    ]
    state.exportTempo = 96.5
    state.gridOffsetSeconds = 0.25
    state.gridDivision = .eighthTriplet
    state.snapEnabled = false
    state.targetProgram = 128
    state.workspace = .edit
    state.playheadSeconds = 12.25
    state.playheadCentered = false
    state.zoomLevel = 3.5
    state.verticalZoom = 2

    try state.save(to: url)

    #expect(try ProjectState.read(from: url) == state)
}

@Test func projectStateMissingFileIsUnreadable() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("no-such-project.json")

    #expect(throws: ProjectError.self) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateCorruptFileIsUnreadable() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try Data("{ this is not json".utf8).write(to: url)

    #expect(throws: ProjectError.self) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateMissingKeyFallsBackToItsDefault() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try Data("{\"exportTempo\": 140}".utf8).write(to: url)

    let loaded = try ProjectState.read(from: url)

    #expect(loaded.exportTempo == 140)
    #expect(loaded.formatVersion == ProjectState.currentFormatVersion)
    #expect(loaded.zoomLevel == 1)
    #expect(loaded.verticalZoom == -1)
    #expect(loaded.playheadCentered)
    #expect(loaded.mixer.isEmpty)
    #expect(loaded.audioFileName == "")
}

@Test func projectStateFromANewerVersionRefusesToLoad() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    let newer = ProjectState.currentFormatVersion + 1
    try Data("{\"formatVersion\": \(newer), \"exportTempo\": 140}".utf8).write(to: url)

    #expect(throws: ProjectError.newerVersion(newer)) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateSaveWritesSortedPrettyJson() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try ProjectState().save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("{\n"))
    #expect(text.contains("\n  \"exportTempo\" : "))
    // Sorted keys: audioFileName precedes exportTempo precedes zoomLevel.
    let audio = try #require(text.range(of: "\"audioFileName\""))
    let tempo = try #require(text.range(of: "\"exportTempo\""))
    let zoom = try #require(text.range(of: "\"zoomLevel\""))
    #expect(audio.lowerBound < tempo.lowerBound)
    #expect(tempo.lowerBound < zoom.lowerBound)
}

// MARK: - parseSelectedGroups

@Test func parseSelectedGroupsDropsUnknownIdsDedupsAndSorts() {
    #expect(ProjectState.parseSelectedGroups("36,0,0,999") == [0, 36])
}

@Test func parseSelectedGroupsOnAnEmptyStringIsEmpty() {
    #expect(ProjectState.parseSelectedGroups("") == [])
    #expect(ProjectState.parseSelectedGroups("   ") == [])
}

@Test func parseSelectedGroupsSortsInEnumeratorOrder() {
    #expect(ProjectState.parseSelectedGroups("33,9,2,19") == [2, 9, 19, 33])
    // 34 and 35 are not group ids; 36 (drums) is the last enumerator.
    #expect(ProjectState.parseSelectedGroups("36,35,34,33") == [33, 36])
}

@Test func parseSelectedGroupsIgnoresJunkAndWhitespace() {
    #expect(ProjectState.parseSelectedGroups(" 7 , banana , -1 , 4 ") == [4, 7])
    #expect(ProjectState.parseSelectedGroups("a,b,c") == [])
}

@Test func parseSelectedGroupsKeepsEveryRealGroupId() {
    let all = InstrumentGroup.allCases.map { String($0.rawValue) }.joined(separator: ",")

    #expect(ProjectState.parseSelectedGroups(all) == InstrumentGroup.allCases.map(\.rawValue))
}
