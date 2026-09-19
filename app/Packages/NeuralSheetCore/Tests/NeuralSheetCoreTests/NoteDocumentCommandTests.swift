import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, amplitude: Double = NoteEvent.defaultAmplitude) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Test func insertAllocatesAnIdAndClampsTheNote() {
    var document = NoteDocument(events: [])
    let batch = document.insert(note(-1, -0.5, pitch: 200, program: 300, amplitude: 4))
    document.commit(batch)

    #expect(batch.title == "Add Note")
    #expect(document.notes.count == 1)
    let inserted = document.notes[0].note
    #expect(inserted.startTime == 0)
    #expect(near(inserted.endTime, NoteDocument.minimumLength))
    #expect(inserted.pitch == 127)
    #expect(inserted.program == 127)
    #expect(inserted.amplitude == 1)
}

@Test func deleteAndDuplicate() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(2, 3, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    let copies = document.duplicate(ids, deltaSeconds: 4, deltaSemitones: 12)
    #expect(copies.title == "Duplicate Notes")
    #expect(copies.inserted.map(\.note) == [note(4, 5, pitch: 72), note(6, 7, pitch: 74)])
    #expect(Set(copies.inserted.map(\.id)).isDisjoint(with: ids))

    let removal = document.delete(ids)
    #expect(removal.title == "Delete Notes")
    document.commit(removal)
    #expect(document.notes.isEmpty)
    #expect(document.delete([]).isEmpty)
}

@Test func moveKeepsRelativeSpacingWhenClampedAtZeroAndAtThePitchEdges() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60), note(3, 4, pitch: 70)])
    let ids = Set(document.notes.map(\.id))

    let batch = document.move(ids, deltaSeconds: -5, deltaSemitones: 60)
    #expect(batch.title == "Move Notes")
    let after = batch.changed.map(\.after.note).sorted()
    // The earliest note stops at 0, and the whole selection moves by that reduced delta.
    #expect(after == [note(0, 1, pitch: 117), note(2, 3, pitch: 127)])

    let single = document.move([document.notes[0].id], deltaSeconds: 0.5, deltaSemitones: -1)
    #expect(single.title == "Move Note")
    #expect(single.changed[0].after.note == note(1.5, 2.5, pitch: 59))
    #expect(document.move(ids, deltaSeconds: 0, deltaSemitones: 0).isEmpty)
}

@Test func resizeStopsAtTheOtherEdgeAndAtZero() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60)])
    let id = document.notes[0].id

    let longer = document.resize([id], edge: .end, deltaSeconds: 1.5)
    #expect(longer.title == "Resize Note")
    #expect(longer.changed[0].after.note == note(1, 3.5, pitch: 60))

    let collapsed = document.resize([id], edge: .end, deltaSeconds: -5)
    #expect(near(collapsed.changed[0].after.note.endTime, 1 + NoteDocument.minimumLength))

    let earlier = document.resize([id], edge: .start, deltaSeconds: -5)
    #expect(earlier.changed[0].after.note == note(0, 2, pitch: 60))

    let crossed = document.resize([id], edge: .start, deltaSeconds: 5)
    #expect(near(crossed.changed[0].after.note.startTime, 2 - NoteDocument.minimumLength))
}

@Test func absoluteSetters() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60, amplitude: 0.5), note(3, 4, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    #expect(document.setStart(ids, seconds: 5).changed.map(\.after.note).sorted() == [note(5, 6, pitch: 60, amplitude: 0.5), note(5, 6, pitch: 62)])
    #expect(document.setLength(ids, seconds: 0.25).changed.map(\.after.note).sorted() == [note(1, 1.25, pitch: 60, amplitude: 0.5), note(3, 3.25, pitch: 62)])
    #expect(document.setPitch(ids, pitch: 40).changed.map(\.after.note.pitch) == [40, 40])
    #expect(document.setProgram(ids, program: NoteEvent.drumProgram).changed.map(\.after.note.program) == [128, 128])
    #expect(document.setProgram(ids, program: 500).changed.map(\.after.note.program) == [127, 127])

    let velocity = document.setVelocity(ids, velocity: 64)
    #expect(velocity.title == "Set Velocity")
    #expect(velocity.changed.map(\.after.note.velocity) == [64, 64])
    #expect(document.setVelocity(ids, velocity: 100).changed.count == 1, "the note already at 100 is not a change")
}

@Test func quantizeSnapsStartsAndOptionallyLengths() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)   // step 0.5
    let document = NoteDocument(events: [note(0.6, 1.3, pitch: 60), note(2.3, 2.35, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    let starts = document.quantize(ids, grid: grid, lengths: false)
    #expect(starts.title == "Quantize")
    let a = starts.changed.map(\.after.note).sorted()
    #expect(near(a[0].startTime, 0.5) && near(a[0].endTime, 1.2))
    #expect(near(a[1].startTime, 2.5) && near(a[1].endTime, 2.55))

    let both = document.quantize(ids, grid: grid, lengths: true)
    let b = both.changed.map(\.after.note).sorted()
    #expect(near(b[0].endTime, 1.0))
    #expect(near(b[1].endTime, 3.0), "never shorter than one division")
}

@Test func overlapOnOneInstrumentAndPitchTrimsTheEarlierNote() {
    var document = NoteDocument(events: [note(0, 2, pitch: 60), note(3, 4, pitch: 60), note(0, 2, pitch: 60, program: 5)])
    let later = document.notes.first { $0.note.startTime == 3 }!

    // Moving the later note back to 1 s overlaps the first: the first is trimmed to end at 1.
    let batch = document.move([later.id], deltaSeconds: -2, deltaSemitones: 0)
    #expect(batch.changed.count == 2)
    document.commit(batch)
    #expect(document.events == [note(0, 1, pitch: 60), note(0, 2, pitch: 60, program: 5), note(1, 2, pitch: 60)])

    // The other instrument's note on the same pitch is untouched, and the trim undoes with the move.
    document.undo()
    #expect(document.events == [note(0, 2, pitch: 60), note(0, 2, pitch: 60, program: 5), note(3, 4, pitch: 60)])

    // Touching notes do not overlap.
    let touching = document.move([later.id], deltaSeconds: -1, deltaSemitones: 0)
    #expect(touching.changed.count == 1)
}

@Test func overlapThatWouldLeaveNothingDeletesTheEarlierNote() {
    var document = NoteDocument(events: [note(1, 2, pitch: 60), note(3, 4, pitch: 60)])
    let first = document.notes[0]
    let second = document.notes[1]

    // The second note dropped exactly onto the first: the first cannot be trimmed to 10 ms.
    document.commit(document.move([second.id], deltaSeconds: -2, deltaSemitones: 0))
    #expect(document.notes.map(\.id) == [second.id])
    #expect(document.events == [note(1, 2, pitch: 60)])

    document.undo()
    #expect(document.notes.map(\.id) == [first.id, second.id])
}

@Test func insertingOverAnExistingNoteTrimsIt() {
    var document = NoteDocument(events: [note(0, 4, pitch: 60)])
    document.commit(document.insert(note(1, 2, pitch: 60)))
    #expect(document.events == [note(0, 1, pitch: 60), note(1, 2, pitch: 60)])
}

@Test func insertingJustBeforeAnExistingNoteInsertsNothing() {
    // The inserted note is the earlier one and would be trimmed to under 10 ms: it is simply not
    // inserted, and the batch is empty.
    var document = NoteDocument(events: [note(1, 2, pitch: 60)])
    let before = document.notes

    let batch = document.insert(note(0.995, 3, pitch: 60))
    #expect(batch.inserted.isEmpty)
    #expect(batch.isEmpty)

    document.commit(batch)
    #expect(document.notes == before)
    #expect(!document.isEdited)
    #expect(!document.canUndo)
}

@Test func movingANoteToJustBeforeAnotherDeletesTheMovedNote() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(3, 4, pitch: 60)])
    let moved = document.notes[0]
    let other = document.notes[1]

    // 5 ms before the other note: the move becomes a deletion of the original.
    let batch = document.move([moved.id], deltaSeconds: 2.995, deltaSemitones: 0)
    #expect(batch.changed.isEmpty)
    #expect(batch.deleted == [moved])

    document.commit(batch)
    #expect(document.notes == [other])

    document.undo()
    #expect(document.notes == [moved, other])
}

@Test func oneMoveOverlappingTwoNeighboursTrimsBothSidesInOneBatch() {
    var document = NoteDocument(events: [note(0, 2, pitch: 60), note(3, 5, pitch: 60), note(6, 8, pitch: 60)])
    let original = document.notes
    let last = document.notes[2]

    // The last note dropped between the other two: the first is trimmed to where it lands, and it
    // is trimmed itself to where the middle one starts.
    let batch = document.move([last.id], deltaSeconds: -4.5, deltaSemitones: 0)
    #expect(batch.changed.count == 2)
    #expect(batch.deleted.isEmpty)

    document.commit(batch)
    #expect(document.events == [note(0, 1.5, pitch: 60), note(1.5, 3, pitch: 60), note(3, 5, pitch: 60)])
    #expect(document.notes.map(\.id) == [original[0].id, last.id, original[1].id])

    document.undo()
    #expect(document.notes == original)
}
