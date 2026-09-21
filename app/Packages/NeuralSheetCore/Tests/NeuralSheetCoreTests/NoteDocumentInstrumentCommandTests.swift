import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program)
}

@Test func reassignMovesEveryNoteOfTheProgramAndMergesOverlaps() {
    var document = NoteDocument(events: [
        note(0, 2, pitch: 60, program: 0),   // piano C4, runs into the guitar's C4
        note(0, 1, pitch: 64, program: 0),
        note(1, 3, pitch: 60, program: 24),  // guitar C4
        note(5, 6, pitch: 40, program: 33),  // bass, untouched
    ])
    let original = document.events

    let batch = document.reassign(program: 0, to: 24)
    #expect(batch.title == "Change Instrument")
    document.commit(batch)

    #expect(document.events.allSatisfy { $0.program != 0 })
    #expect(document.events.filter { $0.program == 33 } == [note(5, 6, pitch: 40, program: 33)])
    // The piano's C4 overlapped the guitar's and is trimmed to where the guitar's starts.
    #expect(document.events.filter { $0.program == 24 && $0.pitch == 60 }
        == [note(0, 1, pitch: 60, program: 24), note(1, 3, pitch: 60, program: 24)])

    #expect(document.reassign(program: 24, to: 24).isEmpty)
    #expect(document.reassign(program: 99, to: 24).isEmpty)

    _ = document.undo()
    #expect(document.events == original)
}

@Test func reassignToDrumsAndBackFollowsSetProgram() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60, program: 0)])
    document.commit(document.reassign(program: 0, to: NoteEvent.drumProgram))
    #expect(document.events == [note(0, 1, pitch: 60, program: NoteEvent.drumProgram)])
    #expect(document.events[0].isDrum)
}

@Test func splitSendsTheNotesOnOneSideOfThePitch() {
    var document = NoteDocument(events: [
        note(0, 1, pitch: 36, program: 0),
        note(0, 1, pitch: 47, program: 0),
        note(0, 1, pitch: 48, program: 0),
        note(0, 1, pitch: 72, program: 0),
        note(0, 1, pitch: 40, program: 33), // another instrument, never moved
    ])
    let original = document.events

    let above = document.split(program: 0, atPitch: 48, sendingAbove: true, to: 33)
    #expect(above.title == "Split Instrument")
    #expect(Set(above.changed.map(\.after.note.pitch)) == [48, 72])
    #expect(above.changed.allSatisfy { $0.after.note.program == 33 })

    let below = document.split(program: 0, atPitch: 48, sendingAbove: false, to: 33)
    #expect(Set(below.changed.map(\.after.note.pitch)) == [36, 47])

    #expect(document.split(program: 0, atPitch: 48, sendingAbove: true, to: 0).isEmpty)
    #expect(document.split(program: 0, atPitch: 100, sendingAbove: true, to: 33).isEmpty)

    document.commit(below)
    #expect(document.events.filter { $0.program == 33 }.map(\.pitch) == [36, 40, 47])
    _ = document.undo()
    #expect(document.events == original)
}

@Test func deleteInstrumentRemovesOnlyThatProgram() {
    var document = NoteDocument(events: [
        note(0, 1, pitch: 60, program: 0),
        note(0, 1, pitch: 36, program: NoteEvent.drumProgram),
        note(2, 3, pitch: 62, program: 0),
    ])
    let original = document.events

    let batch = document.deleteInstrument(program: 0)
    #expect(batch.title == "Delete Instrument")
    #expect(batch.deleted.count == 2)
    document.commit(batch)
    #expect(document.events == [note(0, 1, pitch: 36, program: NoteEvent.drumProgram)])
    #expect(document.deleteInstrument(program: 5).isEmpty)

    _ = document.undo()
    #expect(document.events == original)
}
