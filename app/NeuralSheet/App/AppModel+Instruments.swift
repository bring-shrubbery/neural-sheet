import Foundation
import NeuralSheetCore

/// The strip card's commands (region design §4.1): every note of one instrument at once, one
/// batch each. Edit tab only, and never while a region run owns the notes. No audition: these
/// move whole parts, not a note.
extension AppModel {
    /// Every note of `program` to `destination`; a merge when `destination` is already in the
    /// mix. The target follows: notes drawn next go where the part went.
    func reassignInstrument(_ program: Int, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        // Captured before the commit: applyDocument's validateTargetProgram re-points a target on
        // the vanished program at the mix's first strip before this method can see it, so the
        // check has to run against the target as it stood before the reassignment landed.
        let followsTarget = editor.targetProgram == program

        commit(document.reassign(program: program, to: destination))

        if followsTarget {
            setTargetProgram(destination)
        }
    }

    /// The notes of `program` at or above `pitch` (or below it) to `destination`.
    func splitInstrument(_ program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.split(program: program, atPitch: pitch, sendingAbove: sendingAbove, to: destination))
    }

    /// Every note of `program` gone. Its fader, mute and solo stay in the mixer's settings, so an
    /// undo brings the strip back as it was.
    func deleteInstrument(_ program: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.deleteInstrument(program: program))
    }

    /// The document, when the Edit tab may change it and `program` is a strip; any drag is
    /// cancelled first, since the notes under it are about to change.
    private func editableDocument(for program: Int) -> NoteDocument? {
        guard workspace == .edit, canEdit, let document,
              mixer.entries.contains(where: { $0.program == program })
        else { return nil }

        _ = dragCanceller?()

        return document
    }
}
