import AppKit
import NeuralSheetCore

/// The second buckets a repaint finds its notes by, shared by the notes and the compared
/// version's ghosts (versions design §2). The arithmetic is ``RollPainter``'s; these keep the
/// names the rest of the Mac app calls it by.
extension PianoRollView {
    /// `result[s]` holds the indices of every note of `notes` drawn over second `s`, in note
    /// order: the notes' and the ghosts' buckets alike.
    static func secondBuckets(_ notes: [NoteEvent]) -> [[Int]] {
        RollPainter.secondBuckets(notes)
    }

    /// The same for any notes and their ``secondBuckets(_:)``: the ghosts' too.
    func indices(crossing dirtyRect: CGRect, of notes: [NoteEvent], buckets: [[Int]]) -> [Int] {
        painter.indices(crossing: dirtyRect, of: notes, buckets: buckets)
    }
}
