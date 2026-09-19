import Foundation
import Testing

@testable import NeuralSheetCore

/// A fresh directory under the system temp area. Never the user's real Library.
private func makeSessionTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func sessionStateDefaultsMatchTheApp() {
    let state = SessionState()

    #expect(state.exportTempo == 120)
    #expect(state.midiOverflowMode == .reuseChannels)
    #expect(state.sourceAudioPath == "")
    #expect(state.playheadSeconds == 0)
    #expect(state.playheadCentered)
    #expect(state.zoomLevel == 1)
    #expect(state.verticalZoom == -1)
    #expect(state.selectedGroups.isEmpty)
    #expect(state.mixer.isEmpty)
}

@Test func sessionStateRoundTripsThroughAFile() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")

    var state = SessionState()
    state.exportTempo = 96.5
    state.midiOverflowMode = .dropExtraInstruments
    state.sourceAudioPath = "/tmp/neural-sheet-test/recorded_audio.wav"
    state.playheadSeconds = 12.25
    state.playheadCentered = false
    state.zoomLevel = 3.5
    state.verticalZoom = 2
    state.selectedGroups = [0, 36]
    state.mixer = [
        0: InstrumentChannelSettings(gainDb: -6, muted: true, soloed: false),
        33: InstrumentChannelSettings(gainDb: 1.5, muted: false, soloed: true),
    ]

    try state.save(to: url)

    #expect(SessionState.load(from: url) == state)
}

@Test func sessionStateMissingFileGivesDefaults() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("no-such-session.json")

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(SessionState.load(from: url) == SessionState())
}

@Test func sessionStateCorruptFileGivesDefaults() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.json")
    try Data("{ this is not json".utf8).write(to: url)

    #expect(SessionState.load(from: url) == SessionState())
}

@Test func sessionStateMissingKeyFallsBackToItsDefault() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.json")
    try Data("{\"exportTempo\": 140}".utf8).write(to: url)

    let loaded = SessionState.load(from: url)

    #expect(loaded.exportTempo == 140)
    #expect(loaded.zoomLevel == 1)
    #expect(loaded.verticalZoom == -1)
    #expect(loaded.playheadCentered)
    #expect(loaded.midiOverflowMode == .reuseChannels)
    #expect(loaded.mixer.isEmpty)
}

@Test func sessionStateSaveWritesSortedPrettyJson() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.json")
    try SessionState().save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("{\n"))
    #expect(text.contains("\n  \"exportTempo\" : "))
    // Sorted keys: exportTempo precedes midiOverflowMode precedes zoomLevel.
    let tempo = try #require(text.range(of: "\"exportTempo\""))
    let overflow = try #require(text.range(of: "\"midiOverflowMode\""))
    let zoom = try #require(text.range(of: "\"zoomLevel\""))
    #expect(tempo.lowerBound < overflow.lowerBound)
    #expect(overflow.lowerBound < zoom.lowerBound)
}

// MARK: - parseSelectedGroups

@Test func parseSelectedGroupsDropsUnknownIdsDedupsAndSorts() {
    #expect(SessionState.parseSelectedGroups("36,0,0,999") == [0, 36])
}

@Test func parseSelectedGroupsOnAnEmptyStringIsEmpty() {
    #expect(SessionState.parseSelectedGroups("") == [])
    #expect(SessionState.parseSelectedGroups("   ") == [])
}

@Test func parseSelectedGroupsSortsInEnumeratorOrder() {
    #expect(SessionState.parseSelectedGroups("33,9,2,19") == [2, 9, 19, 33])
    // 34 and 35 are not group ids; 36 (drums) is the last enumerator.
    #expect(SessionState.parseSelectedGroups("36,35,34,33") == [33, 36])
}

@Test func parseSelectedGroupsIgnoresJunkAndWhitespace() {
    #expect(SessionState.parseSelectedGroups(" 7 , banana , -1 , 4 ") == [4, 7])
    #expect(SessionState.parseSelectedGroups("a,b,c") == [])
}

@Test func parseSelectedGroupsKeepsEveryRealGroupId() {
    let all = InstrumentGroup.allCases.map { String($0.rawValue) }.joined(separator: ",")

    #expect(SessionState.parseSelectedGroups(all) == InstrumentGroup.allCases.map(\.rawValue))
}

@Test func sessionStateNewFieldsDefault() {
    let state = SessionState()
    #expect(state.transcription == nil)
    #expect(state.workspace == .transcribe)
    #expect(state.gridOffsetSeconds == 0)
    #expect(state.gridDivision == .sixteenth)
    #expect(state.snapEnabled)
    #expect(state.targetProgram == nil)
}

@Test func sessionStateRoundTripsATranscription() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")

    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0), NoteEvent(startTime: 1, endTime: 2, pitch: 38, program: 128)]
    var document = NoteDocument(events: raw)
    document.commit(document.delete([document.notes[0].id]))

    var state = SessionState()
    state.transcription = SessionTranscription(sourceSampleCount: 160_000, rawNotes: raw, document: document)
    state.workspace = .edit
    state.gridOffsetSeconds = 0.25
    state.gridDivision = .eighthTriplet
    state.snapEnabled = false
    state.targetProgram = 128

    try state.save(to: url)
    let loaded = SessionState.load(from: url)

    #expect(loaded.transcription?.sourceSampleCount == 160_000)
    #expect(loaded.transcription?.rawNotes == raw)
    #expect(loaded.transcription?.document.notes == document.notes)
    #expect(loaded.transcription?.document.isEdited == true)
    #expect(loaded.workspace == .edit)
    #expect(loaded.gridOffsetSeconds == 0.25)
    #expect(loaded.gridDivision == .eighthTriplet)
    #expect(!loaded.snapEnabled)
    #expect(loaded.targetProgram == 128)
}

@Test func sessionStateWithoutTheNewKeysStillLoads() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")
    try Data(#"{"exportTempo": 90, "zoomLevel": 2}"#.utf8).write(to: url)

    let loaded = SessionState.load(from: url)
    #expect(loaded.exportTempo == 90)
    #expect(loaded.zoomLevel == 2)
    #expect(loaded.transcription == nil)
    #expect(loaded.workspace == .transcribe)
}
