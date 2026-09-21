import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program)
}

@Test func replaceOwnsNotesByWhereTheyStart() {
    var document = NoteDocument(events: [
        note(0, 3, pitch: 60),     // crosses the start: kept whole
        note(2, 3, pitch: 64),     // starts inside: deleted
        note(4.9, 7, pitch: 67),   // starts inside, runs past the end: deleted
        note(5, 6, pitch: 69),     // starts at the upper bound: kept
        note(8, 9, pitch: 71),     // after: kept
    ])
    let original = document.events
    let existingIDs = Set(document.notes.map(\.id))

    let batch = document.replace(range: 1 ..< 5, with: [
        note(0.5, 1.5, pitch: 62), // starts in the margin: dropped
        note(1, 2, pitch: 62),     // kept
        note(4, 6.5, pitch: 65),   // runs past the end: keeps its length
        note(5, 6, pitch: 72),     // starts at the upper bound: dropped
    ])

    #expect(batch.title == "Re-transcribe")
    #expect(batch.deleted.map(\.note) == [note(2, 3, pitch: 64), note(4.9, 7, pitch: 67)])
    #expect(batch.inserted.map(\.note) == [note(1, 2, pitch: 62), note(4, 6.5, pitch: 65)])
    #expect(Set(batch.inserted.map(\.id)).isDisjoint(with: existingIDs))

    document.commit(batch)
    #expect(document.events == [
        note(0, 3, pitch: 60), note(1, 2, pitch: 62), note(4, 6.5, pitch: 65), note(5, 6, pitch: 69), note(8, 9, pitch: 71),
    ])

    _ = document.undo()
    #expect(document.events == original)
}

@Test func replaceTrimsSeamOverlapsOnOneInstrumentAndPitch() {
    var document = NoteDocument(events: [
        note(0, 3, pitch: 60),              // sounding into the range; the new C4 at 2 cuts it
        note(6, 8, pitch: 60),              // after the range; the new C4 running to 7 is cut by it
        note(6, 8, pitch: 60, program: 24), // another instrument: not touched
    ])

    let batch = document.replace(range: 1 ..< 5, with: [note(2, 2.5, pitch: 60), note(4, 7, pitch: 60)])
    document.commit(batch)

    #expect(document.events == [
        note(0, 2, pitch: 60), note(2, 2.5, pitch: 60), note(4, 6, pitch: 60),
        note(6, 8, pitch: 60), note(6, 8, pitch: 60, program: 24),
    ])
}

@Test func replaceWithNothingDeletesTheRangeAndIsEmptyWhenNothingChanges() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(2, 3, pitch: 62)])

    let cleared = document.replace(range: 1.5 ..< 4, with: [])
    #expect(cleared.deleted.map(\.note) == [note(2, 3, pitch: 62)])
    #expect(cleared.inserted.isEmpty)

    #expect(document.replace(range: 5 ..< 6, with: [note(7, 8, pitch: 60)]).isEmpty)
}
