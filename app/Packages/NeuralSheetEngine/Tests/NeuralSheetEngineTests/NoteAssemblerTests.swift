// Note assembly and the reference's cleanup passes, against the same vectors the
// tracker tests replay. Recording both the actions and the notes is what makes a
// disagreement name which of the two ports broke.
//
// Runs with no weights and no reference dump.

import Testing

@testable import NeuralSheetEngine

/// Compares note lists field by field, with the times to `timeTolerance`.
private func expectNotesEqual(_ got: [Note], _ want: [Note], _ name: String) {
    #expect(got.count == want.count, "\(name): note count, got \(got)")
    guard got.count == want.count else { return }

    for (index, pair) in zip(got, want).enumerated() {
        #expect(pair.0.pitch == pair.1.pitch, "\(name): note \(index) pitch")
        #expect(pair.0.program == pair.1.program, "\(name): note \(index) program")
        #expect(pair.0.isDrum == pair.1.isDrum, "\(name): note \(index) isDrum")
        #expect(abs(pair.0.onset - pair.1.onset) <= timeTolerance, "\(name): note \(index) onset")
        #expect(abs(pair.0.offset - pair.1.offset) <= timeTolerance, "\(name): note \(index) offset")
    }
}

@Test func everyVectorProducesTheReferenceNoteList() throws {
    for vector in try Fixtures.noteVectors() {
        expectNotesEqual(try vector.replayNotes(), vector.notes, vector.name)
    }
}

@Test func closedInMatchesFinalizePerChunk() throws {
    // The streaming callback's contract: concatenating what each chunk reports has to
    // equal finalize(), or a progressively-filling piano roll ends up showing notes the
    // finished transcription disagrees with.
    for vector in try Fixtures.noteVectors() {
        var tracker = OpenNoteTracker()
        var assembler = NoteAssembler()
        let boundaries = vector.boundaries
        let lastChunk = boundaries.count - 1
        var streamed: [Note] = []

        for (chunk, boundary) in boundaries.enumerated() {
            try assembler.apply(tracker.feed(boundary: boundary), chunkIndex: chunk)

            for id in vector.chunkTokens[chunk] {
                try assembler.apply(tracker.feed(token: id), chunkIndex: chunk)
            }

            // Notes from chunk k - 1 are only final once chunk k has closed.
            if chunk > 0 {
                streamed += assembler.closedIn(chunkIndex: chunk - 1)
            }
        }

        // The withheld tail is the last chunk only; every earlier one went out as soon
        // as its successor closed.
        try assembler.apply(tracker.finish(), chunkIndex: lastChunk)
        streamed += assembler.closedIn(chunkIndex: lastChunk)

        NoteAssembler.sort(&streamed)
        expectNotesEqual(streamed, assembler.finalize(), vector.name)
    }
}

@Test func anEndWithNothingOpenThrows() {
    var assembler = NoteAssembler()

    #expect(throws: TranscriberError.self) {
        try assembler.apply([NoteAction(kind: .end, program: 0, pitch: 60, time: 1.0)], chunkIndex: 0)
    }
}

@Test func aRetriggerWidensToTenMilliseconds() throws {
    // Retriggering at the same tick makes a zero-length note. validate widens it to the
    // 10 ms minimum, then trimming clamps it back against the next onset and drops it:
    // the action stream still carries it, the note list must not.
    var tracker = OpenNoteTracker()
    var assembler = NoteAssembler()
    _ = tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: nil))

    let ids: [Int32] = [
        tokenID(.tie),
        tokenID(.shift, 50), tokenID(.program, 0), tokenID(.velocity, 1), tokenID(.pitch, 60),
        tokenID(.velocity, 1), tokenID(.pitch, 60),
        tokenID(.shift, 100), tokenID(.velocity, 0), tokenID(.pitch, 60),
    ]

    for id in ids {
        try assembler.apply(tracker.feed(token: id), chunkIndex: 0)
    }

    try assembler.apply(tracker.finish(), chunkIndex: 0)

    expectNotesEqual(
        assembler.finalize(),
        [Note(onset: 0.5, offset: 1.0, pitch: 60, program: 0, isDrum: false)],
        "retrigger")
}

@Test func drumHitsAreInstantaneousAndRoutedToTheDrumProgram() throws {
    var assembler = NoteAssembler()
    try assembler.apply([NoteAction(kind: .drumHit, program: 0, pitch: 36, time: 0.1)], chunkIndex: 0)

    expectNotesEqual(
        assembler.finalize(),
        [Note(onset: 0.1, offset: 0.1 + Note.minimumDuration, pitch: 36, program: Note.drumProgram, isDrum: true)],
        "drum")
}

@Test func trimmingBreaksAnOnsetTieOnCloseOrder() {
    // The vectors never reach this, but the reference's choice of a stable sort on onset
    // *alone* is what decides it: two coincident notes on one channel truncate in close
    // order, so the first one closed is the one that collapses to nothing. Sorting the
    // group by the full five-key comparator instead would keep the other note.
    let notes = [
        Note(onset: 1.0, offset: 2.0, pitch: 60, program: 0, isDrum: false),
        Note(onset: 1.0, offset: 1.5, pitch: 60, program: 0, isDrum: false),
    ]

    expectNotesEqual(NoteAssembler.trimOverlapping(notes), [notes[1]], "onset tie")
}

@Test func validateRepairsInvertedAndTooShortNotes() {
    var notes = [
        // onset > offset takes the first branch: the offset moves to whichever is later.
        Note(onset: 3.0, offset: 1.0, pitch: 60, program: 0, isDrum: false),
        // Shorter than the minimum, and melodic, so it widens.
        Note(onset: 0.0, offset: 0.004, pitch: 62, program: 0, isDrum: false),
        // A drum hit is exempt: it is instantaneous by definition.
        Note(onset: 0.0, offset: 0.004, pitch: 36, program: Note.drumProgram, isDrum: true),
    ]

    NoteAssembler.validate(&notes)
    #expect(notes.map(\.offset) == [3.01, 0.01, 0.004])
}

@Test func sortIsTheReferencesFiveKeyOrder() {
    // Melodic before drums at the same onset, then program, pitch and offset.
    var notes = [
        Note(onset: 1.0, offset: 2.0, pitch: 36, program: Note.drumProgram, isDrum: true),
        Note(onset: 1.0, offset: 2.0, pitch: 64, program: 0, isDrum: false),
        Note(onset: 1.0, offset: 1.5, pitch: 64, program: 0, isDrum: false),
        Note(onset: 0.5, offset: 2.0, pitch: 60, program: 8, isDrum: false),
    ]

    NoteAssembler.sort(&notes)
    #expect(notes.map(\.pitch) == [60, 64, 64, 36])
    #expect(notes.map(\.offset) == [2.0, 1.5, 2.0, 2.0])
}
