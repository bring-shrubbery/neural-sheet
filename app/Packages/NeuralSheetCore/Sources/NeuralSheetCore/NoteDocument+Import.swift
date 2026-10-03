import Foundation

/// A MIDI file's notes laid over a transcription (MIDI import design §2).
extension NoteDocument {
    /// Every note of `notes` at its own time, replacing the document's notes or added to them, as
    /// one batch titled "Import MIDI" so one Undo takes it back. Not `paste`: that moves the
    /// earliest note to where it is put, and a file's notes belong where the file has them.
    /// Overlaps on one instrument and pitch, within the file or against the notes kept, are
    /// trimmed by `finished` as every edit's are. The notes are not the model's, so they carry
    /// no confidence. Mutating, since the inserted notes need ids.
    public mutating func importing(_ notes: [NoteEvent], replacing: Bool) -> EditBatch {
        let doomed = replacing ? self.notes : []
        var inserted: [EditableNote] = []

        for var note in notes.sorted() {
            note.confidence = nil
            inserted.append(EditableNote(id: allocateID(), note: note))
        }

        return finished(EditBatch(title: "Import MIDI", inserted: inserted, deleted: doomed))
    }
}
