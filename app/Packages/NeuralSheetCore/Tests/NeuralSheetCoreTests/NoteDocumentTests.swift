import Foundation
import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, amplitude: Double = NoteEvent.defaultAmplitude) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

@Test func velocityIsAmplitudeTimes127ClampedTo1Through127() {
    #expect(note(0, 1, pitch: 60).velocity == 100)
    #expect(note(0, 1, pitch: 60, amplitude: 0).velocity == 1)
    #expect(note(0, 1, pitch: 60, amplitude: 1).velocity == 127)
    #expect(note(0, 1, pitch: 60, amplitude: 0.5).velocity == 64)
    #expect(NoteEvent.amplitude(forVelocity: 64) == 64.0 / 127.0)
    #expect(NoteEvent.amplitude(forVelocity: 300) == 1)
    #expect(NoteEvent.amplitude(forVelocity: -3) == 1.0 / 127.0)
}

@Test func initSortsAndNumbersTheNotes() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60), note(0, 1, pitch: 62)])
    #expect(document.notes.map(\.id.raw) == [0, 1])
    #expect(document.events == [note(0, 1, pitch: 62), note(1, 2, pitch: 60)])
    #expect(document.note(NoteID(1))?.note == note(1, 2, pitch: 60))
    #expect(document.note(NoteID(7)) == nil)
    #expect(!document.isEdited)
    #expect(!document.canUndo)
}

@Test func commitAppliesDeletesChangesAndInsertsThenSorts() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(1, 2, pitch: 62)])
    let a = document.notes[0]
    let b = document.notes[1]
    let c = EditableNote(id: document.allocateID(), note: note(0.5, 1, pitch: 64))
    let batch = EditBatch(title: "Test",
                          inserted: [c],
                          deleted: [a],
                          changed: [NoteChange(before: b, after: EditableNote(id: b.id, note: note(0.2, 2, pitch: 62)))])

    document.commit(batch)

    #expect(document.events == [note(0.2, 2, pitch: 62), note(0.5, 1, pitch: 64)])
    #expect(document.notes.map(\.id) == [b.id, c.id])
    #expect(document.isEdited)
    #expect(document.canUndo)
    #expect(document.undoTitle == "Test")
    #expect(!document.canRedo)
}

@Test func undoAndRedoRoundTrip() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let original = document.notes
    let a = document.notes[0]

    document.commit(EditBatch(title: "Move Note", changed: [NoteChange(before: a, after: EditableNote(id: a.id, note: note(3, 4, pitch: 60)))]))
    let edited = document.notes

    #expect(document.undo()?.title == "Move Note")
    #expect(document.notes == original)
    #expect(document.canRedo)
    #expect(document.redoTitle == "Move Note")
    #expect(document.isEdited, "undo-to-start does not un-edit the document")

    #expect(document.redo()?.title == "Move Note")
    #expect(document.notes == edited)
    #expect(document.undo() != nil)
    #expect(document.undo() == nil)
}

@Test func aCommitClearsRedoAndAnEmptyBatchIsIgnored() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]
    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    _ = document.undo()
    #expect(document.canRedo)

    document.commit(EditBatch(title: "Nothing"))
    #expect(document.canRedo, "an empty batch changes nothing")
    #expect(document.undoStack.isEmpty)

    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    #expect(!document.canRedo)
}

@Test func undoHistoryIsCapped() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]

    for step in 1...(NoteDocument.undoLimit + 5) {
        let before = document.notes[0]
        document.commit(EditBatch(title: "Step \(step)", changed: [NoteChange(before: before, after: EditableNote(id: a.id, note: note(Double(step), Double(step) + 1, pitch: 60)))]))
    }

    #expect(document.undoStack.count == NoteDocument.undoLimit)
    #expect(document.undoTitle == "Step \(NoteDocument.undoLimit + 5)")
}

@Test func codableKeepsNotesAndEditedFlagButNotHistory() throws {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]
    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    let inserted = EditableNote(id: document.allocateID(), note: note(2, 3, pitch: 61))
    document.commit(EditBatch(title: "Add Note", inserted: [inserted]))

    let data = try JSONEncoder().encode(document)
    var decoded = try JSONDecoder().decode(NoteDocument.self, from: data)

    #expect(decoded.notes == document.notes)
    #expect(decoded.isEdited)
    #expect(!decoded.canUndo)
    #expect(!decoded.canRedo)
    // The id counter survives, so a new note never collides with a restored one.
    #expect(decoded.allocateID().raw > inserted.id.raw)
}

@Test func noteIdEncodesAsABareInteger() throws {
    let data = try JSONEncoder().encode(EditableNote(id: NoteID(7), note: note(0, 1, pitch: 60)))
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.contains("\"id\":7"))
    #expect(!json.contains("raw"))
    #expect(try JSONDecoder().decode(EditableNote.self, from: data).id == NoteID(7))
}

@Test func decodedIdCounterNeverCollidesWithAStoredId() throws {
    // A hand-edited file whose counter lags its ids: the counter moves past them.
    let json = #"{"notes":[{"id":9,"note":{"startTime":0,"endTime":1,"pitch":60,"amplitude":0.8,"program":0}}],"isEdited":false,"nextID":2}"#
    var document = try JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8))

    #expect(document.allocateID() == NoteID(10))
}

@Test func noteIdDecodesFromABareIntegerOrTheOlderKeyedForm() throws {
    #expect(try JSONDecoder().decode(NoteID.self, from: Data("7".utf8)) == NoteID(7))
    #expect(try JSONDecoder().decode(NoteID.self, from: Data(#"{"raw":7}"#.utf8)) == NoteID(7))
}
