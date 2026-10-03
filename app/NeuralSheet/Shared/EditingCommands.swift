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

    // MARK: - Lyrics

    /// The note's syllable from its typed form (a trailing "-" continues the word, "_" holds it),
    /// read against the previous syllable of its instrument, as one "Lyric" batch.
    static func lyric(in document: NoteDocument, id: NoteID, typed text: String) -> EditBatch {
        document.setLyric(id: id, Lyric.typed(text, after: document.previousNote(sameProgramAs: id)?.note.lyric))
    }

    /// The notes Paste Lyrics hands the syllables to, in time order: the selection, or with none
    /// selected every note of the target instrument.
    static func pasteLyricsTargets(in document: NoteDocument, editor: EditorState) -> [NoteID] {
        // `notes` is in start order already; the selection's order is the document's.
        let targets = editor.selection.isEmpty
            ? document.notes.filter { $0.note.program == editor.targetProgram }
            : document.notes.filter { editor.selection.contains($0.id) }

        return targets.map(\.id)
    }

    // MARK: - Clipboard

    /// The selected notes in document order, what Copy puts on the pasteboard; empty with
    /// nothing selected.
    static func selectedNotes(in document: NoteDocument, selection: Set<NoteID>) -> [NoteEvent] {
        guard !selection.isEmpty else { return [] }

        return document.notes.filter { selection.contains($0.id) }.map(\.note)
    }

    /// Cut's delete, titled as a cut.
    static func cut(in document: NoteDocument, selection: Set<NoteID>) -> EditBatch {
        var batch = document.delete(selection)
        batch.title = selection.count == 1
            ? String(localized: "Cut Note", comment: "Undo title: one note cut")
            : String(localized: "Cut Notes", comment: "Undo title: several notes cut")

        return batch
    }

    // MARK: - Confidence

    /// The notes Select Doubtful Notes picks: under 50 %, or shorter than `minimumLength` when
    /// that is on (above 0). A drawn note counts as sure.
    static func doubtfulNotes(in document: NoteDocument, minimumLength: Double) -> Set<NoteID> {
        Set(document.notes.filter { NoteFilter.isDoubtful($0.note, minimumLength: minimumLength) }.map(\.id))
    }

    /// Whether there is a doubtful note at all; stops at the first.
    static func hasDoubtfulNotes(in document: NoteDocument, minimumLength: Double) -> Bool {
        document.notes.contains { NoteFilter.isDoubtful($0.note, minimumLength: minimumLength) }
    }
}
