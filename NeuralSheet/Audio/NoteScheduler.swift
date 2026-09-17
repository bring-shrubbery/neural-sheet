import Foundation
import NeuralSheetCore

// Stub — implemented in Task 12.
//
// The real one is the port of the C++ `NoteScheduler`: a 512-note active set with oldest-stealing,
// a 30 s lookback when a seek or a swapped note list has to re-anchor sounding notes, and note-offs
// emitted before note-ons at equal offsets. Until then it holds no notes and answers nothing, which
// is exactly right for a build with no synth in it.
nonisolated final class NoteScheduler: @unchecked Sendable {
    init() {}

    /// Replaces the note list, once per decoded chunk.
    func swap(notes: [NoteEvent]) {
        _ = notes
    }

    /// Re-anchors to a new transport position.
    func seek(toSeconds seconds: Double) {
        _ = seconds
    }

    /// Asks for a clean set of note-offs on the next block.
    func requestAllNotesOff() {}
}
