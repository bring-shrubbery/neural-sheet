import Foundation
import NeuralSheetCore

/// Editing on touch (sub-issue F): the Mac's `AppModel+Editing` rules over the same document --
/// every change to the notes is an `EditBatch` committed here, never a write to the notes.
///
/// Undo has one source of truth, the document's own stack. Each commit also registers an entry
/// with the document's `UndoManager` (what marks an iOS document edited and autosaves it, and what
/// three-finger swipe and shake-to-undo drive), and that entry does nothing but call the
/// document's undo, registering its redo as it goes; so the two stacks move together whichever is
/// used. The bottom bar's buttons go through the manager too when there is one.
extension MobileModel {
    // MARK: - Availability

    /// A document the user may change: a finished transcription, no run or recording in flight.
    var canEdit: Bool { document != nil && run == nil && recording == nil }

    var canUndo: Bool { canEdit && (document?.canUndo ?? false) }
    var canRedo: Bool { canEdit && (document?.canRedo ?? false) }

    /// "Move Note" in the user's language, or nil with nothing to undo.
    var undoTitle: String? { canUndo ? document?.undoTitle.map(CoreNames.localized) : nil }
    var redoTitle: String? { canRedo ? document?.redoTitle.map(CoreNames.localized) : nil }

    // MARK: - Commits

    /// The batch on the document, then the notes to the synths and the scheduler, as the Mac's
    /// `commit` and `applyDocument` do; and one entry with the undo manager.
    func commit(_ batch: EditBatch) {
        guard canEdit, var document, !batch.isEmpty else { return }

        document.commit(batch)
        self.document = document
        applyDocument()
        registerDocumentUndo(title: batch.title)
    }

    /// For the builders that allocate ids (insert, split, restore): the copy they ran on becomes
    /// the document, then the batch is committed on it.
    func replaceDocumentAndCommit(_ document: NoteDocument, _ batch: EditBatch) {
        guard canEdit, !batch.isEmpty else { return }

        self.document = document
        commit(batch)
    }

    /// What follows every change of the document: the selection keeps only notes that are still
    /// there, and the notes go down to the synths, the mixer and the scheduler.
    func applyDocument() {
        guard let document else { return }

        let kept = editor.selection.filter(document.contains)

        if kept != editor.selection {
            editor.selection = kept
        }

        publishNotes()
    }

    // MARK: - Undo

    /// The bottom bar's Undo and the two-finger tap.
    func undo() {
        guard canUndo else { return }

        _ = dragCanceller?()

        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            undoDocumentEdit()
        }
    }

    func redo() {
        guard canRedo else { return }

        _ = dragCanceller?()

        if let undoManager, undoManager.canRedo {
            undoManager.redo()
        } else {
            redoDocumentEdit()
        }
    }

    /// The document's undo, which an undo manager entry or the button runs.
    private func undoDocumentEdit() {
        guard var document, let batch = document.undo() else { return }

        self.document = document
        applyDocument()

        undoManager?.registerUndo(withTarget: self) { model in
            model.redoDocumentEdit()
        }
        undoManager?.setActionName(CoreNames.localized(batch.title))
    }

    private func redoDocumentEdit() {
        guard var document, let batch = document.redo() else { return }

        self.document = document
        applyDocument()
        registerDocumentUndo(title: batch.title)
    }

    private func registerDocumentUndo(title: String) {
        guard let undoManager else { return }

        undoManager.registerUndo(withTarget: self) { model in
            model.undoDocumentEdit()
        }
        undoManager.setActionName(CoreNames.localized(title))
    }

    // MARK: - Selection

    func setSelection(_ ids: Set<NoteID>) {
        guard let document else { return }

        let valid = ids.filter(document.contains)

        if valid != editor.selection {
            editor.selection = valid
        }
    }

    func selectAll() {
        guard let document else { return }

        setSelection(Set(document.notes.map(\.id)))
    }

    func deselectAll() {
        if !editor.selection.isEmpty {
            editor.selection = []
        }
    }

    /// Select Doubtful Notes: under 50 %, or shorter than the Mac's minimum note length when that
    /// setting is on (it is the Mac's, and off here until the settings arrive with sub-issue H).
    func selectDoubtfulNotes() {
        guard canEdit, let document else { return }

        setSelection(EditingCommands.doubtfulNotes(in: document, minimumLength: 0))
    }

    var canSelectDoubtfulNotes: Bool {
        guard canEdit, let document else { return false }

        return EditingCommands.hasDoubtfulNotes(in: document, minimumLength: 0)
    }

    /// The selected notes in document order.
    var selectedNotes: [NoteEvent] {
        guard let document else { return [] }

        return EditingCommands.selectedNotes(in: document, selection: editor.selection)
    }

    // MARK: - Tools

    func setTool(_ tool: EditorState.Tool) {
        _ = dragCanceller?()

        if editor.tool != tool {
            editor.tool = tool
        }
    }

    func setSnapEnabled(_ enabled: Bool) {
        if editor.snapEnabled != enabled {
            editor.snapEnabled = enabled
        }
    }

    // MARK: - Gestures' commits

    /// A drag of the selection on the roll, landed.
    func moveNotes(_ ids: Set<NoteID>, deltaSeconds: Double, deltaSemitones: Int) {
        guard let document, deltaSeconds != 0 || deltaSemitones != 0 else { return }

        commit(document.move(ids, deltaSeconds: deltaSeconds, deltaSemitones: deltaSemitones))
    }

    /// A drag of a selected note's end, landed: every note of `ids` by the same amount.
    func resizeNotes(_ ids: Set<NoteID>, edge: NoteEdge, deltaSeconds: Double) {
        guard let document, deltaSeconds != 0 else { return }

        commit(document.resize(ids, edge: edge, deltaSeconds: deltaSeconds))
    }

    /// A note drawn or tapped in with the Draw tool: inserted, selected and heard.
    func insertNote(_ note: NoteEvent) {
        guard canEdit, var document else { return }

        let batch = document.insert(note)
        replaceDocumentAndCommit(document, batch)
        setSelection(Set(batch.inserted.map(\.id)))
        audition(note)
    }

    func deleteSelection() {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.delete(editor.selection))
    }

    // MARK: - The note card's fields

    func setSelectionStart(_ seconds: Double) {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.setStart(editor.selection, seconds: seconds))
    }

    func setSelectionLength(_ seconds: Double) {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.setLength(editor.selection, seconds: seconds))
    }

    func setSelectionPitch(_ pitch: Int) {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.setPitch(editor.selection, pitch: pitch))
        auditionSelection()
    }

    func setSelectionVelocity(_ velocity: Int) {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.setVelocity(editor.selection, velocity: velocity))
        auditionSelection()
    }

    /// The selection to `program`, which also becomes the target the Draw tool draws in, as on
    /// the Mac; the first note is heard.
    func setSelectionProgram(_ program: Int) {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.setProgram(editor.selection, program: program))

        if editor.targetProgram != program {
            editor.targetProgram = program
        }

        auditionSelection()
    }

    /// The one selected note's syllable from its typed form.
    func setSelectedLyric(_ text: String) {
        guard canEdit, editor.selection.count == 1, let id = editor.selection.first, let document else { return }

        commit(EditingCommands.lyric(in: document, id: id, typed: text))
    }

    /// The instrument the Draw tool draws in.
    func setTargetProgram(_ program: Int) {
        if editor.targetProgram != program {
            editor.targetProgram = program
        }
    }

    /// The first selected note in document order, after a change that applied to all of them.
    func auditionSelection() {
        guard let first = selectedNotes.first else { return }

        audition(first)
    }

    // MARK: - Status

    /// The line under the roll: "3 instruments · 412 notes · C2–G5", or the selection's count
    /// when there is one.
    var statusLine: String? {
        guard let document, !document.notes.isEmpty else { return nil }

        let notes = document.events
        let instruments = Set(notes.map(\.program)).count
        let low = notes.map(\.pitch).min() ?? 0
        let high = notes.map(\.pitch).max() ?? 0
        let range = "\(TimeFormat.pitchName(low))–\(TimeFormat.pitchName(high))"
        let selected = editor.selection.count

        let summary = String(localized: "\(instruments) instruments · \(notes.count) notes · \(range)",
                             comment: "Roll screen's status line: how many instruments and notes, and the pitch range, e.g. \"3 instruments · 412 notes · C2–G5\"")

        guard selected > 0 else { return summary }

        return String(localized: "\(selected) selected · \(summary)",
                      comment: "Roll screen's status line with a selection: how many notes are selected, then the summary")
    }
}
