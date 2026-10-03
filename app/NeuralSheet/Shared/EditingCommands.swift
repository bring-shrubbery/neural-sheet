import Foundation
import NeuralSheetCore

/// The editing commands' arithmetic, shared by the Mac's `AppModel` and the iPhone and iPad's
/// `MobileModel` (iOS app design §3, item 3): each one works out a batch, a selection or a list
/// from the document, the editor state and the command's own inputs, and touches nothing else --
/// no window, pasteboard, panel, engine or undo stack. The models commit what comes back and do
/// the rest (cancel a drag, audition, ask first) themselves.
///
/// A command that finds nothing to do answers an empty batch, which a commit ignores.
nonisolated enum EditingCommands {
    // MARK: - What a command acts on

    /// The selection, or every note when nothing is selected: what Quantize and every bulk
    /// command act on.
    static func selectionOrAll(_ selection: Set<NoteID>, in document: NoteDocument) -> Set<NoteID> {
        selection.isEmpty ? Set(document.notes.map(\.id)) : selection
    }

    // MARK: - Nudge

    /// Arrow keys: `steps` grid divisions at the selection's tempo (or 10 ms each with snap off),
    /// `semitones` up. The earliest selected note's start picks the tempo; with none, the
    /// playhead's.
    static func nudge(in document: NoteDocument, editor: EditorState, steps: Int, semitones: Int,
                      playheadSeconds: Double) -> EditBatch {
        let selection = editor.selection
        let earliest = document.notes.filter { selection.contains($0.id) }.map(\.note.startTime).min() ?? playheadSeconds
        let seconds = Double(steps) * (editor.snapEnabled ? editor.grid.step(atSeconds: earliest) : 0.010)

        return document.move(selection, deltaSeconds: seconds, deltaSemitones: semitones)
    }

    // MARK: - Grid and scale

    /// The selection, or everything when nothing is selected; starts only.
    static func quantize(in document: NoteDocument, editor: EditorState) -> EditBatch {
        document.quantize(selectionOrAll(editor.selection, in: document), grid: editor.grid, lengths: false)
    }

    /// Edit → Snap to Scale: the selection, or everything when nothing is selected, onto the
    /// key's scale; nil without a key.
    static func snapToScale(in document: NoteDocument, editor: EditorState) -> EditBatch? {
        guard let key = editor.key else { return nil }

        return document.snapToScale(selectionOrAll(editor.selection, in: document), key: key)
    }
}
