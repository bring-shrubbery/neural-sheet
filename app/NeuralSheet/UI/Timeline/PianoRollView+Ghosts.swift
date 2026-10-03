import AppKit
import NeuralSheetCore

/// The ghosts: Compare With's version drawn behind the notes in both tabs, its notes stroked 1 px
/// in the instrument's colour at half alpha with no fill (versions design §2). A note the
/// version shares is covered by its own fill, so what is left hollow is what differs.
extension PianoRollView {
    /// Replaces the ghosts; empty for none. Whole-view repaint. A note with a non-finite time
    /// cannot be placed and is left out, as ``setNotes(_:)`` does; the filter only copies when
    /// there is one, so the usual case keeps sharing the model's array.
    func setGhosts(_ notes: [NoteEvent]) {
        guard !(notes.isEmpty && ghosts.notes.isEmpty) else { return }

        let isPlaceable: (NoteEvent) -> Bool = { $0.startTime.isFinite && $0.endTime.isFinite }
        let placeable = notes.allSatisfy(isPlaceable) ? notes : notes.filter(isPlaceable)

        painter.ghosts = placeable.isEmpty ? GhostNotes() : GhostNotes(notes: placeable, buckets: RollPainter.secondBuckets(placeable))
        needsDisplay = true
    }
}
