import Foundation

/// Whole-instrument commands (instrument commands design §3.1): every note of one program at
/// once. Each is one batch through the same invariants as the per-note commands, so a merge
/// that lands two notes of one instrument on one pitch at once trims the earlier the way a
/// per-note reassign does.
extension NoteDocument {
    /// Every note of `program` given `destination`. With `destination` already in the mix this is
    /// the merge. Empty for no such notes, or a destination that is the program itself.
    public func reassign(program: Int, to destination: Int) -> EditBatch {
        guard destination != program else { return EditBatch(title: "Change Instrument") }

        return changing(notes(ofProgram: program), title: "Change Instrument") { note in
            var note = note
            note.program = destination

            return note
        }
    }

    /// The notes of `program` at or above `pitch` -- or, with `sendingAbove` false, below it --
    /// given `destination`. The boundary pitch itself goes above.
    public func split(program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) -> EditBatch {
        guard destination != program else { return EditBatch(title: "Split Instrument") }

        let moving = notes(ofProgram: program).filter { sendingAbove ? $0.note.pitch >= pitch : $0.note.pitch < pitch }

        return changing(moving, title: "Split Instrument") { note in
            var note = note
            note.program = destination

            return note
        }
    }

    /// Every note of `program` deleted.
    public func deleteInstrument(program: Int) -> EditBatch {
        EditBatch(title: "Delete Instrument", deleted: notes(ofProgram: program))
    }

    /// The notes of one instrument, in document order.
    func notes(ofProgram program: Int) -> [EditableNote] {
        notes.filter { $0.note.program == program }
    }
}
