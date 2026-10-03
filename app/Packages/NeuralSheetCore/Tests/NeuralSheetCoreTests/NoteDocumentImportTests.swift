import Testing

@testable import NeuralSheetCore

// A MIDI file's notes over a transcription (MIDI import design §2).

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, confidence: Double? = nil) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program, confidence: confidence)
}

@Test func importAddsTheFilesNotesAtTheirOwnTimes() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60, confidence: 0.9)])
    let batch = document.importing([note(5, 6, pitch: 64, confidence: 0.5), note(3, 4, pitch: 62)], replacing: false)
    document.commit(batch)

    #expect(batch.title == "Import MIDI")
    #expect(batch.deleted.isEmpty)
    #expect(batch.inserted.map(\.note) == [note(3, 4, pitch: 62), note(5, 6, pitch: 64)], "not moved, no confidence")
    #expect(document.events.count == 3)
    #expect(document.events[0].confidence == 0.9, "the transcription's notes keep theirs")

    document.undo()
    #expect(document.events == [note(0, 1, pitch: 60, confidence: 0.9)])
}

@Test func importCanReplaceEveryNoteInOneUndoableStep() {
    let original = [note(0, 1, pitch: 60), note(1, 2, pitch: 60)]
    var document = NoteDocument(events: original)
    // Overlaps the old C4s, which must not be trimmed: they are going.
    let batch = document.importing([note(0.5, 1.5, pitch: 60)], replacing: true)
    document.commit(batch)

    #expect(batch.changed.isEmpty)
    #expect(document.events == [note(0.5, 1.5, pitch: 60)])

    document.undo()
    #expect(document.events == original)
}

@Test func importTrimsOverlapsAsAnyEditDoes() {
    var document = NoteDocument(events: [note(0, 2, pitch: 60)])
    document.commit(document.importing([note(1, 3, pitch: 60), note(1.5, 4, pitch: 60)], replacing: false))

    #expect(document.events.map(\.endTime) == [1, 1.5, 4])
}
