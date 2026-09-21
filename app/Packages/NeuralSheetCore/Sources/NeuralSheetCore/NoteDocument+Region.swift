import Foundation

/// The region re-run's landing (design §3.1, §5.1): the notes starting in a range swapped for
/// the run's notes starting in it.
extension NoteDocument {
    /// A note is owned by where it starts, so one crossing the range's start is kept whole and
    /// one crossing its end keeps its length. Notes in `notes` that start outside the range came
    /// from the run's context margin and are dropped. Seam overlaps on one instrument and pitch
    /// are trimmed by `finished`. Mutating, since the inserted notes need ids.
    public mutating func replace(range: Range<Double>, with notes: [NoteEvent]) -> EditBatch {
        let doomed = self.notes.filter { range.contains($0.note.startTime) }
        var inserted: [EditableNote] = []

        for note in notes.sorted() where range.contains(note.startTime) {
            inserted.append(EditableNote(id: allocateID(), note: note))
        }

        return finished(EditBatch(title: "Re-transcribe", inserted: inserted, deleted: doomed))
    }
}
