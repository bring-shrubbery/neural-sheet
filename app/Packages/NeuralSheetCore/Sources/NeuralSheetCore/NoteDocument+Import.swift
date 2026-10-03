import Foundation

/// Notes laid over a transcription at their own times: a MIDI file's (MIDI import design §2) and
/// a restored version's (versions design §2).
extension NoteDocument {
    /// Every note of `notes` at its own time, replacing the document's notes or added to them, as
    /// one batch titled "Import MIDI" so one Undo takes it back. Not `paste`: that moves the
    /// earliest note to where it is put, and a file's notes belong where the file has them.
    /// Overlaps on one instrument and pitch, within the file or against the notes kept, are
    /// trimmed by `finished` as every edit's are. The notes are not the model's, so they carry
    /// no confidence. Mutating, since the inserted notes need ids.
    public mutating func importing(_ notes: [NoteEvent], replacing: Bool) -> EditBatch {
        laying(notes.map { note in
            var note = note
            note.confidence = nil
            return note
        }, replacing: replacing, title: "Import MIDI")
    }

    /// Every note of the document swapped for `notes` as one batch titled `title`, so one Undo
    /// brings the old notes back (versions design §2: "Restore <name>"). The notes keep their
    /// confidence, curves and lyrics: a version is the document's own notes, taken earlier. They
    /// get fresh ids, since the ids they were saved with may since have been given to others.
    public mutating func replaceAll(with notes: [NoteEvent], title: String) -> EditBatch {
        laying(notes, replacing: true, title: title)
    }

    /// The shared body: fresh ids in note order, the old notes deleted when replacing, and the
    /// invariants every edit gets.
    private mutating func laying(_ notes: [NoteEvent], replacing: Bool, title: String) -> EditBatch {
        let doomed = replacing ? self.notes : []
        var inserted: [EditableNote] = []

        for note in notes.sorted() {
            inserted.append(EditableNote(id: allocateID(), note: note))
        }

        return finished(EditBatch(title: title, inserted: inserted, deleted: doomed))
    }
}
