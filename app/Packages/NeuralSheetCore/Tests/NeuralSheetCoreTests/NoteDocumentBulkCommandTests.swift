import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, velocity: Int = 100,
                  confidence: Double? = nil) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: NoteEvent.amplitude(forVelocity: velocity),
              program: program, confidence: confidence)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// SplitMix64: a seeded generator, so humanize is reproducible here.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func applied(_ document: NoteDocument, _ batch: EditBatch) -> [NoteEvent] {
    var document = document
    document.commit(batch)
    return document.events
}

// MARK: - setVelocities

@Test func setVelocitiesClampsAndSkipsUnchangedNotes() {
    let document = NoteDocument(events: [note(0, 1, pitch: 60, velocity: 100), note(1, 2, pitch: 62, velocity: 10)])
    let ids = Set(document.notes.map(\.id))

    let doubled = document.setVelocities(ids, title: "Scale Velocity") { $0 * 2 }
    #expect(doubled.title == "Scale Velocity")
    #expect(applied(document, doubled).map(\.velocity) == [127, 20])

    let floored = document.setVelocities(ids) { $0 - 500 }
    #expect(applied(document, floored).map(\.velocity) == [1, 1])

    #expect(document.setVelocities(ids) { $0 }.isEmpty)
}

// MARK: - Legato

@Test func legatoEndsAtTheNextNoteOfTheInstrumentWhateverItsPitch() {
    let document = NoteDocument(events: [
        note(0, 0.2, pitch: 60),
        note(1, 1.5, pitch: 64),           // the successor, another pitch
        note(0.5, 3, pitch: 50, program: 1), // another instrument: ignored
    ])
    let first = document.notes.first { $0.note.pitch == 60 }!.id

    let batch = document.legato([first])
    #expect(batch.title == "Legato")
    #expect(batch.changed.count == 1)
    #expect(near(batch.changed[0].after.note.endTime, 1))
}

@Test func legatoShortensANoteThatReachesPastItsSuccessorAndLeavesTheLastAlone() {
    let document = NoteDocument(events: [note(0, 2, pitch: 60), note(1, 1.5, pitch: 64)])
    let ids = Set(document.notes.map(\.id))

    let events = applied(document, document.legato(ids))
    #expect(near(events[0].endTime, 1))
    // No successor: unchanged.
    #expect(near(events[1].endTime, 1.5))
}

@Test func legatoAgainstASuccessorAtTheSameStartLooksPastIt() {
    // Two notes of a chord share a start; neither is the other's successor.
    let document = NoteDocument(events: [note(0, 0.5, pitch: 60), note(0, 0.5, pitch: 64), note(2, 3, pitch: 67)])
    let ids = Set(document.notes.map(\.id))

    let events = applied(document, document.legato(ids))
    #expect(events.filter { $0.startTime == 0 }.allSatisfy { near($0.endTime, 2) })
}

@Test func legatoNeverLeavesLessThanTheMinimumLength() {
    let document = NoteDocument(events: [note(0, 1, pitch: 60), note(0.001, 1, pitch: 64)])
    let first = document.notes[0].id

    let batch = document.legato([first])
    #expect(near(batch.changed[0].after.note.endTime, NoteDocument.minimumLength))
}

// MARK: - Join

@Test func joinMergesARunAndLeavesAWiderGap() {
    let document = NoteDocument(events: [
        note(0, 1, pitch: 60),
        note(1.03, 2, pitch: 60),
        note(2.04, 3, pitch: 60),
        note(3.5, 4, pitch: 60),  // 0.5 s after: stays apart
        note(1, 2, pitch: 62),    // another pitch: untouched
    ])
    let ids = Set(document.notes.map(\.id))

    let batch = document.join(ids, gap: 0.05)
    #expect(batch.title == "Join Notes")
    #expect(batch.deleted.count == 2)

    let events = applied(document, batch).filter { $0.pitch == 60 }
    #expect(events.count == 2)
    #expect(near(events[0].startTime, 0) && near(events[0].endTime, 3))
    #expect(near(events[1].startTime, 3.5))
}

@Test func joinKeepsTheFirstNotesIdVelocityAndConfidence() {
    let document = NoteDocument(events: [
        note(0, 1, pitch: 60, velocity: 40, confidence: 0.3),
        note(1.01, 2, pitch: 60, velocity: 110, confidence: 0.9),
    ])
    let firstID = document.notes[0].id

    var after = document
    after.commit(after.join(Set(document.notes.map(\.id)), gap: 0.05))
    #expect(after.notes.count == 1)
    #expect(after.notes[0].id == firstID)
    #expect(after.notes[0].note.velocity == 40)
    #expect(after.notes[0].note.confidence == 0.3)
}

@Test func joinDoesNotReachAcrossANoteOutsideTheSet() {
    let document = NoteDocument(events: [note(0, 1, pitch: 60), note(1, 1.01, pitch: 60), note(1.02, 2, pitch: 60)])
    let ends = Set([document.notes[0].id, document.notes[2].id])

    #expect(document.join(ends, gap: 0.05).isEmpty)
}

// MARK: - Split

@Test func splitMakesTwoHalvesAndSkipsNotesThePlayheadDoesNotCross() {
    var document = NoteDocument(events: [
        note(0, 2, pitch: 60, velocity: 70, confidence: 0.8),
        note(3, 4, pitch: 62),          // after the playhead
        note(0.995, 1.5, pitch: 64),    // first half would be under 10 ms
    ])
    let ids = Set(document.notes.map(\.id))
    let crossed = document.notes.first { $0.note.pitch == 60 }!.id

    let (batch, halves) = document.split(ids, at: 1)
    #expect(batch.title == "Split Note")
    #expect(batch.changed.count == 1 && batch.inserted.count == 1)
    #expect(batch.changed[0].after.id == crossed)
    #expect(!ids.contains(batch.inserted[0].id))
    #expect(halves == [crossed, batch.inserted[0].id])

    document.commit(batch)
    let pieces = document.notes.filter { halves.contains($0.id) }.map(\.note)
    #expect(pieces.count == 2)
    #expect(near(pieces[0].startTime, 0) && near(pieces[0].endTime, 1))
    #expect(near(pieces[1].startTime, 1) && near(pieces[1].endTime, 2))
    #expect(pieces.allSatisfy { $0.velocity == 70 && $0.confidence == 0.8 && $0.pitch == 60 })
}

// MARK: - Humanize

@Test func humanizeIsDeterministicUnderASeedAndStaysWithinBounds() {
    let events = (0..<40).map { note(Double($0) * 0.5 + 0.005, Double($0) * 0.5 + 0.3, pitch: 60 + $0 % 5, velocity: $0 % 2 == 0 ? 4 : 124) }
    let document = NoteDocument(events: events)
    let ids = Set(document.notes.map(\.id))

    var a = SeededGenerator(state: 42)
    var b = SeededGenerator(state: 42)
    let first = document.humanize(ids, timing: 0.012, velocity: 8, using: &a)
    let second = document.humanize(ids, timing: 0.012, velocity: 8, using: &b)

    #expect(first == second)
    #expect(first.title == "Humanize")
    #expect(!first.isEmpty)

    for change in first.changed {
        let before = change.before.note
        let after = change.after.note
        let shift = after.startTime - before.startTime

        #expect(abs(shift) <= 0.012 + 1e-12)
        #expect(after.startTime >= 0)
        #expect(near(after.endTime - after.startTime, before.endTime - before.startTime))
        #expect(abs(after.velocity - before.velocity) <= 8)
        #expect((1...127).contains(after.velocity))
    }
}
