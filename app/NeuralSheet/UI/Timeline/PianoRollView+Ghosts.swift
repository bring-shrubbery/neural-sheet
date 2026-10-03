import AppKit
import NeuralSheetCore

/// A compared version's notes and their second buckets (versions design §2). The notes are the
/// model's own array, shared rather than copied, and the buckets are built once when the
/// comparison changes, so a repaint touches only the ghosts that cross the sliver.
struct GhostNotes {
    var notes: [NoteEvent] = []
    var buckets: [[Int]] = []
}

/// The ghosts: Compare With's version drawn behind the notes in both tabs, its notes stroked 1 px
/// in the instrument's colour at half alpha with no fill (versions design §2). A note the
/// version shares is covered by its own fill, so what is left hollow is what differs.
extension PianoRollView {
    static let ghostAlpha: CGFloat = 0.5

    /// Replaces the ghosts; empty for none. Whole-view repaint. A note with a non-finite time
    /// cannot be placed and is left out, as ``setNotes(_:)`` does; the filter only copies when
    /// there is one, so the usual case keeps sharing the model's array.
    func setGhosts(_ notes: [NoteEvent]) {
        guard !(notes.isEmpty && ghosts.notes.isEmpty) else { return }

        let isPlaceable: (NoteEvent) -> Bool = { $0.startTime.isFinite && $0.endTime.isFinite }
        let placeable = notes.allSatisfy(isPlaceable) ? notes : notes.filter(isPlaceable)

        ghosts = placeable.isEmpty ? GhostNotes() : GhostNotes(notes: placeable, buckets: PianoRollView.secondBuckets(placeable))
        needsDisplay = true
    }

    /// The ghosts crossing the exposed sliver, windowed by their buckets like the notes.
    func drawGhosts(_ ctx: CGContext, in dirtyRect: CGRect) {
        guard !ghosts.notes.isEmpty else { return }

        let k = geometry.scale
        let lineWidth = 1 * k

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setAlpha(PianoRollView.ghostAlpha)

        for index in indices(crossing: dirtyRect, of: ghosts.notes, buckets: ghosts.buckets) {
            let note = ghosts.notes[index]

            guard let rect = noteRect(note), rect.maxX >= dirtyRect.minX, rect.minX <= dirtyRect.maxX else { continue }

            let program = min(max(note.program, 0), NoteEvent.drumProgram)
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let corner = min(PianoRollView.noteCorner * k, inset.width / 2, inset.height / 2)

            ctx.setStrokeColor(colours[program])
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, corner), cornerHeight: max(0, corner), transform: nil))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }
}
