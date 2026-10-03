import Foundation
import Testing

@testable import NeuralSheetCore

// Per-note confidence in the core (confidence design §4): the field, its file form, the
// commands that must keep or clear it, and the settings around it.

private func note(_ start: Double, _ end: Double, pitch: Int = 60, confidence: Double? = 0.4) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: 0, confidence: confidence)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func confidenceDefaultsToNilAndReadsAsSure() {
    let drawn = NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)

    #expect(drawn.confidence == nil)
    #expect(drawn.confidenceOrSure == 1)
    #expect(note(0, 1).confidenceOrSure == 0.4)
}

@Test func aNoteWithoutConfidenceWritesNoKey() throws {
    let text = String(decoding: try JSONEncoder().encode(note(0, 1, confidence: nil)), as: UTF8.self)

    #expect(!text.contains("confidence"))
}

@Test func aNoteFromBeforeTheFieldDecodesAsNil() throws {
    let json = #"{"startTime":0,"endTime":1,"pitch":60,"amplitude":0.5,"program":0}"#
    let decoded = try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8))

    #expect(decoded.confidence == nil)
    #expect(decoded.pitch == 60)
}

@Test func projectTranscriptionRoundTripsConfidenceWithAndWithout() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transcription.json")

    let raw = [note(0, 1, confidence: 0.72), note(1, 2, pitch: 62, confidence: nil)]
    let transcription = ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw))
    try transcription.save(to: url)

    let loaded = try #require(ProjectTranscription.load(from: url))
    #expect(loaded.rawNotes.map(\.confidence) == [0.72, nil])
    #expect(loaded.document.events.map(\.confidence) == [0.72, nil])
}

@Test func insertLeavesConfidenceNil() {
    var document = NoteDocument(events: [])
    let batch = document.insert(note(0, 1, confidence: 0.3))

    #expect(batch.inserted.map(\.note.confidence) == [nil])
}

@Test func pasteKeepsWhatTheClipboardNoteHad() {
    var document = NoteDocument(events: [])
    let batch = document.paste([note(0, 1, confidence: 0.3), note(1, 2, pitch: 62, confidence: nil)], at: 5)

    #expect(batch.inserted.map(\.note.confidence) == [0.3, nil])
}

@Test func editsKeepConfidence() {
    let document = NoteDocument(events: [note(0, 1, confidence: 0.3), note(2, 3, pitch: 50, confidence: 0.6)])
    let ids = Set(document.notes.map(\.id))

    let batches = [
        document.move(ids, deltaSeconds: 1, deltaSemitones: 2),
        document.resize(ids, edge: .end, deltaSeconds: 0.5),
        document.setPitch(ids, pitch: 70),
        document.setVelocity(ids, velocity: 40),
        document.setProgram(ids, program: 33),
    ]

    for batch in batches {
        #expect(Set(batch.changed.map(\.after.note.confidence)) == [0.3, 0.6], "\(batch.title)")
    }
}

@Test func anInstrumentSplitKeepsConfidenceOnBothSides() {
    let document = NoteDocument(events: [note(0, 1, pitch: 40, confidence: 0.3), note(0, 1, pitch: 60, confidence: 0.8)])
    let batch = document.split(program: 0, atPitch: 48, sendingAbove: true, to: 33)
    var after = document
    after.commit(batch)

    #expect(after.events.map(\.confidence).sorted { ($0 ?? 0) < ($1 ?? 0) } == [0.3, 0.8])
}

@Test func confidenceSettingsDefaultOffAndRoundTrip() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("global.settings")

    let defaults = GlobalSettings()
    #expect(!defaults.showsConfidence)
    #expect(defaults.minimumNoteLength == 0)
    #expect(defaults.minimumConfidence == 0)

    var settings = GlobalSettings()
    settings.showsConfidence = true
    settings.minimumNoteLength = 0.05
    settings.minimumConfidence = 0.25
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url) == settings)
}

@Test func confidenceSettingsMissingFromAnOlderFileFallBack() throws {
    let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>separateStems</key><true/></dict></plist>"#
    let loaded = try PropertyListDecoder().decode(GlobalSettings.self, from: Data(plist.utf8))

    #expect(loaded.separateStems)
    #expect(!loaded.showsConfidence)
    #expect(loaded.minimumNoteLength == 0)
    #expect(loaded.minimumConfidence == 0)
}
