import Foundation

/// The lyric commands (markers and lyrics design §2): one syllable from the entry card, a verse
/// from the clipboard. Each is one ``EditBatch``, so the words undo like any other note edit.
extension NoteDocument {
    /// The note `id` given `lyric`, nil clearing it: one commit of the entry card. Empty when the
    /// note is gone or already has it.
    public func setLyric(id: NoteID, _ lyric: Lyric?, title: String = "Lyric") -> EditBatch {
        guard let source = note(id), source.note.lyric != lyric else { return EditBatch(title: title) }

        var after = source.note
        after.lyric = lyric

        return finished(EditBatch(title: title, changed: [NoteChange(before: source, after: EditableNote(id: id, note: after))]))
    }

    /// The syllables handed out in order to the notes `ids` names, in that order (the caller sorts
    /// them by time): Paste Lyrics, one batch. Notes past the last syllable are left as they are;
    /// syllables past the last note are not used, and `leftOver` says how many, for the dialog.
    public func setLyrics(_ ids: [NoteID], lyrics: [Lyric],
                          title: String = "Paste Lyrics") -> (batch: EditBatch, leftOver: Int) {
        var batch = EditBatch(title: title)
        var used = 0

        for (id, lyric) in zip(ids, lyrics) {
            guard let source = note(id) else { continue }

            used += 1

            guard source.note.lyric != lyric else { continue }

            var after = source.note
            after.lyric = lyric
            batch.changed.append(NoteChange(before: source, after: EditableNote(id: id, note: after)))
        }

        return (finished(batch), lyrics.count - used)
    }

    /// The note of the same instrument that starts next after `id` (by start, then the document's
    /// order for a tie): where the entry card goes on Return or Tab. Nil after the last.
    public func nextNote(sameProgramAs id: NoteID) -> EditableNote? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }

        let program = notes[index].note.program

        return notes[(index + 1)...].first { $0.note.program == program }
    }

    /// The note of the same instrument just before `id`: whose syllable decides whether the one
    /// typed now begins a word or continues it.
    public func previousNote(sameProgramAs id: NoteID) -> EditableNote? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }

        let program = notes[index].note.program

        return notes[..<index].last { $0.note.program == program }
    }
}
