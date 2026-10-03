import Foundation
import Testing

@testable import NeuralSheetCore

// Versions of the notes (versions design §3): the file, the restore and the matcher.

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, confidence: Double? = nil) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program, confidence: confidence)
}

// MARK: - Project file

@Test func versionsRoundTripThroughTheTranscriptionFile() throws {
    let raw = [note(0, 1, pitch: 60, confidence: 0.8)]
    var curved = note(2, 3, pitch: 64)
    curved.pitchCurve = [0, 10, -5]
    curved.lyric = Lyric(text: "la")
    let version = NoteVersion(name: "small", date: Date(timeIntervalSinceReferenceDate: 812_000_000.5),
                              notes: [curved, note(4, 5, pitch: 67, confidence: 0.4)])
    let transcription = ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw,
                                             document: NoteDocument(events: raw), versions: [version])

    let data = try JSONEncoder().encode(transcription)
    let loaded = try JSONDecoder().decode(ProjectTranscription.self, from: data)

    #expect(loaded.versions == [version])
    #expect(loaded == transcription)
}

@Test func aTranscriptionFromBeforeVersionsReadsBackWithNone() throws {
    let raw = [note(0, 1, pitch: 60)]
    let transcription = ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw))
    let data = try JSONEncoder().encode(transcription)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(!json.contains("versions"), "an empty list writes no key, as before")

    let loaded = try JSONDecoder().decode(ProjectTranscription.self, from: data)
    #expect(loaded.versions.isEmpty)
    #expect(loaded.rawNotes == raw)
}

@Test func aVersionIsPartOfTheProjectsContent() {
    let raw = [note(0, 1, pitch: 60)]
    let plain = ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw))
    var saved = plain
    saved.versions = [NoteVersion(name: "a", notes: raw)]

    #expect(plain != saved)
}

@Test func theTranscriptionEntryIsTheMergedRawNotes() {
    let version = NoteVersion.transcription(rawNotes: [note(0, 2, pitch: 60), note(1, 3, pitch: 60)])

    #expect(version.isTranscription)
    #expect(version.name == "Transcription")
    #expect(version.notes == [note(0, 3, pitch: 60)])
}

// MARK: - Restore

@Test func replaceAllSwapsEveryNoteAndUndoesToTheOldOnes() {
    let old = [note(0, 1, pitch: 60, confidence: 0.9), note(1, 2, pitch: 62)]
    var restored = note(0.5, 1.5, pitch: 60, confidence: 0.3)
    restored.lyric = Lyric(text: "oh")
    var document = NoteDocument(events: old)
    let batch = document.replaceAll(with: [restored, note(3, 4, pitch: 70)], title: "Restore small")
    document.commit(batch)

    #expect(batch.title == "Restore small")
    #expect(document.undoTitle == "Restore small")
    #expect(document.events == [restored, note(3, 4, pitch: 70)], "confidence and lyric kept")
    #expect(Set(document.notes.map(\.id)).isDisjoint(with: [NoteID(0), NoteID(1)]), "fresh ids")

    document.undo()
    #expect(document.events == old)

    document.redo()
    #expect(document.events.count == 2)
}

// MARK: - Matcher

@Test func identicalNotesHaveNoDifferences() {
    let notes = [note(0, 1, pitch: 60), note(0, 1, pitch: 64), note(1, 2, pitch: 60, program: 33)]
    let document = NoteDocument(events: notes)
    let result = NoteMatcher.unmatched(current: document.notes, against: notes)

    #expect(result.added.isEmpty)
    #expect(result.missing.isEmpty)
}

@Test func aNoteMovedBeyondTheToleranceIsAddedAndMissing() {
    let before = [note(0, 1, pitch: 60), note(2, 3, pitch: 62)]
    let document = NoteDocument(events: [note(0, 1, pitch: 60), note(2.1, 3.1, pitch: 62)])
    let result = NoteMatcher.unmatched(current: document.notes, against: before)

    #expect(result.added == [document.notes[1].id])
    #expect(result.missing == [note(2, 3, pitch: 62)])
}

@Test func aNoteShiftedWithinTheToleranceMatches() {
    let before = [note(1, 2, pitch: 60)]
    let document = NoteDocument(events: [note(1.02, 2.05, pitch: 60)])
    let result = NoteMatcher.unmatched(current: document.notes, against: before)

    #expect(result.added.isEmpty)
    #expect(result.missing.isEmpty)
}

@Test func anotherInstrumentOrPitchIsNoCounterpart() {
    let before = [note(0, 1, pitch: 60, program: 0)]
    let document = NoteDocument(events: [note(0, 1, pitch: 60, program: 33), note(0, 1, pitch: 61)])
    let result = NoteMatcher.unmatched(current: document.notes, against: before)

    #expect(result.added.count == 2)
    #expect(result.missing == before)
}

@Test func matchingIsOneToOneAndPrefersTheNearestStart() {
    // Two current notes both within tolerance of one old note: the nearer one matches it.
    let before = [note(1, 2, pitch: 60)]
    let document = NoteDocument(events: [note(0.98, 2, pitch: 60), note(1.005, 2, pitch: 60, program: 0)])
    let result = NoteMatcher.unmatched(current: document.notes, against: before)
    let far = document.notes.first { $0.note.startTime == 0.98 }!.id

    #expect(result.added == [far])
    #expect(result.missing.isEmpty)
}
