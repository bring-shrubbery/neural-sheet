// The decode state machine against the reference's hand-authored vectors, which
// reach rules the audio fixture never does: a shift before a tie, shift 0, a
// non-monotonic shift and an event past the chunk window.
//
// Runs with no weights and no reference dump.

import Testing

@testable import NeuralSheetEngine

/// Times are derived by the same arithmetic on both sides, so this is tight on purpose.
let timeTolerance = 1e-12

/// Compares against the reference's action stream field by field.
///
/// A drum hit's program is not compared: the fixture omits it because the reference's
/// drum action has no program, and the tracker fills in a zero it never reads.
private func expectActionsEqual(_ got: [NoteAction], _ want: [NoteAction], _ name: String) {
    #expect(got.count == want.count, "\(name): action count")
    guard got.count == want.count else { return }

    for (index, pair) in zip(got, want).enumerated() {
        #expect(pair.0.kind == pair.1.kind, "\(name): action \(index) kind")
        #expect(pair.0.pitch == pair.1.pitch, "\(name): action \(index) pitch")
        #expect(abs(pair.0.time - pair.1.time) <= timeTolerance, "\(name): action \(index) time")

        if pair.1.kind != .drumHit {
            #expect(pair.0.program == pair.1.program, "\(name): action \(index) program")
        }
    }
}

/// The token id for an event, for the tests that spell a chunk out by hand.
func tokenID(_ type: EventType, _ value: Int32 = 0) -> Int32 {
    Vocabulary.token(for: type, value: value)
}

@Test func everyVectorProducesTheReferenceActionStream() throws {
    for vector in try Fixtures.noteVectors() {
        expectActionsEqual(vector.replayActions(), vector.actions, vector.name)
    }
}

@Test func openKeysAtEachBoundaryMatchTheReference() throws {
    // This is what prelude forcing reads, so checking it on its own means a wrong
    // forced prologue localises here with no transformer involved.
    for vector in try Fixtures.noteVectors() {
        var tracker = OpenNoteTracker()
        let boundaries = vector.boundaries
        #expect(vector.openKeysAtBoundary.count == boundaries.count, "\(vector.name): boundary count")

        for (chunk, boundary) in boundaries.enumerated() {
            _ = tracker.feed(boundary: boundary)

            // Read after feeding the boundary, never before: the boundary settles a
            // previous chunk that ended mid-prologue, and only then is this the
            // decoder's own view.
            #expect(tracker.openKeys == vector.openKeysAtBoundary[chunk], "\(vector.name): boundary \(chunk)")

            for id in vector.chunkTokens[chunk] {
                _ = tracker.feed(token: id)
            }
        }
    }
}

@Test func aShiftBeforeTieClosesEverythingAndSkipsTheChunk() {
    var tracker = OpenNoteTracker()
    var actions: [NoteAction] = []

    actions += tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: 5))

    for id in [tokenID(.tie), tokenID(.shift, 50), tokenID(.program, 0), tokenID(.velocity, 1), tokenID(.pitch, 60)] {
        actions += tracker.feed(token: id)
    }

    actions += tracker.feed(boundary: ChunkBoundary(seekTime: 5, nextSeekTime: nil))

    // The shift arrives with no tie before it, so the chunk never wrote a prologue:
    // everything open closes at *this* chunk's boundary and the rest of the chunk is
    // discarded, the later tie and pitch included.
    for id in [tokenID(.shift, 10), tokenID(.tie), tokenID(.program, 0), tokenID(.velocity, 1), tokenID(.pitch, 72)] {
        actions += tracker.feed(token: id)
    }

    actions += tracker.finish()

    #expect(actions == [
        NoteAction(kind: .start, program: 0, pitch: 60, time: 0.5),
        NoteAction(kind: .end, program: 0, pitch: 60, time: 5.0),
    ])
    #expect(tracker.openKeys.isEmpty)
}

@Test func theOpenSetKeepsInsertionOrderNotKeyOrder() {
    // finish() replays its closes in insertion order, and that order reaches the
    // assembler, where it decides which of two coincident notes gets truncated.
    var tracker = OpenNoteTracker()
    _ = tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: nil))

    for id in [tokenID(.tie), tokenID(.shift, 10), tokenID(.program, 0), tokenID(.velocity, 1)] {
        _ = tracker.feed(token: id)
    }

    for pitch in [72, 60, 64] as [Int32] {
        _ = tracker.feed(token: tokenID(.pitch, pitch))
    }

    #expect(tracker.finish().map(\.pitch) == [72, 60, 64])
}

@Test func resetForgetsEverything() {
    var tracker = OpenNoteTracker()
    _ = tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: nil))

    for id in [tokenID(.tie), tokenID(.shift, 10), tokenID(.program, 0), tokenID(.velocity, 1), tokenID(.pitch, 60)] {
        _ = tracker.feed(token: id)
    }

    #expect(!tracker.openKeys.isEmpty)
    tracker.reset()
    #expect(tracker.openKeys.isEmpty)
    #expect(tracker.finish().isEmpty)
}
