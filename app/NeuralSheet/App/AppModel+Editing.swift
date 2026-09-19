import Foundation
import NeuralSheetCore

/// The editor's own state, shared on the model because the AppKit roll and the SwiftUI inspector
/// both read it (design §5.3).
struct EditorState: Equatable {
    enum Tool: Equatable {
        case select, draw, erase
    }

    var tool: Tool = .select
    var selection: Set<NoteID> = []
    /// The instrument new and reassigned notes go to. Re-validated against the mixer's entries.
    var targetProgram: Int = 0
    var snapEnabled = true
    var grid = TempoGrid()

    /// A drawn or inserted note is one division long.
    var drawLength: Double { grid.step }
}

/// The document's place in the model and the commands the Edit tab calls (design §5).
extension AppModel {
    // MARK: - Workspace

    var canEdit: Bool { state == .populated && document != nil }

    // MARK: - Document

    var hasEdits: Bool { document?.isEdited ?? false }

    /// Makes the document from the model's own output. The merge is the post-processing every
    /// raw note goes through; from here on the document's invariants replace it.
    func installDocument(rawNotes: [NoteEvent], document: NoteDocument? = nil) {
        transcription.rawNotes = rawNotes
        self.document = document ?? NoteDocument(events: mergeOverlappingNotesWithSamePitch(rawNotes))
        editor.selection = []
        applyDocument()
    }

    /// The only writer of `transcription.notes` once a document exists: the document's events go
    /// down the same path a decoded chunk did — synths first, then the mixer, then the scheduler.
    func applyDocument() {
        guard let document else { return }

        transcription.notes = document.events
        editor.selection = editor.selection.filter(document.contains)
        publishNotes()
        validateTargetProgram()
    }

    /// If the target instrument has left the mix, the first strip takes over.
    private func validateTargetProgram() {
        let programs = mixer.entries.map(\.program)

        if !programs.contains(editor.targetProgram), let first = programs.first {
            editor.targetProgram = first
        }
    }

    // MARK: - Commits and history

    func commit(_ batch: EditBatch) {
        guard var document, !batch.isEmpty else { return }

        document.commit(batch)
        self.document = document
        applyDocument()
    }

    /// For the two builders that allocate ids: the copy they ran on becomes the document, then the
    /// batch is committed on it.
    func replaceDocumentAndCommit(_ document: NoteDocument, _ batch: EditBatch) {
        guard !batch.isEmpty else { return }

        self.document = document
        commit(batch)
    }

    var canUndo: Bool { document?.canUndo ?? false }
    var canRedo: Bool { document?.canRedo ?? false }
    var undoMenuTitle: String { document?.undoTitle.map { "Undo \($0)" } ?? "Undo" }
    var redoMenuTitle: String { document?.redoTitle.map { "Redo \($0)" } ?? "Redo" }

    // Undo, redo and select-all are guarded on the workspace here as well as at the menu, since
    // the menu items stay enabled whatever the tab (their routing is decided when chosen).

    func undo() {
        guard workspace == .edit, var document, document.canUndo else { return }

        _ = dragCanceller?()
        document.undo()
        self.document = document
        applyDocument()
    }

    func redo() {
        guard workspace == .edit, var document, document.canRedo else { return }

        _ = dragCanceller?()
        document.redo()
        self.document = document
        applyDocument()
    }

    /// Back to the model's own output, after asking (design §2).
    func revertToTranscription() {
        guard document != nil, hasEdits else { return }

        confirmDiscardingEdits(action: "Reverting to the transcription") { [weak self] in
            guard let self else { return }

            _ = dragCanceller?()
            installDocument(rawNotes: transcription.rawNotes)
        }
    }

    /// Runs `proceed` at once when there is nothing to lose, otherwise after the user agrees.
    func confirmDiscardingEdits(action: String, proceed: @escaping () -> Void) {
        guard hasEdits, let presentConfirm else {
            proceed()
            return
        }

        presentConfirm("Discard your edits?",
                       "The transcription has been edited. \(action) will throw the edits away.",
                       "Discard") { confirmed in
            if confirmed {
                proceed()
            }
        }
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
        guard workspace == .edit, let document else { return }

        editor.selection = Set(document.notes.map(\.id))
    }

    func deselectAll() {
        if !editor.selection.isEmpty {
            editor.selection = []
        }
    }

    func deleteSelection() {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.delete(editor.selection))
    }

    /// Arrow keys: `steps` grid divisions (or 10 ms each with snap off), `semitones` up.
    func nudgeSelection(steps: Int, semitones: Int) {
        guard let document, !editor.selection.isEmpty else { return }

        let seconds = Double(steps) * (editor.snapEnabled ? editor.grid.step : 0.010)

        commit(document.move(editor.selection, deltaSeconds: seconds, deltaSemitones: semitones))
    }

    /// Escape: a drag in progress is cancelled; otherwise the selection goes.
    func escapePressed() {
        if dragCanceller?() == true { return }

        deselectAll()
    }

    // MARK: - Tools and grid

    func setTool(_ tool: EditorState.Tool) {
        _ = dragCanceller?()
        editor.tool = tool
    }

    func setSnapEnabled(_ enabled: Bool) {
        editor.snapEnabled = enabled
    }

    func setGridDivision(_ division: GridDivision) {
        editor.grid.division = division
    }

    func setGridBpm(_ bpm: Double) {
        editor.grid.bpm = TempoGrid.clampedBpm(bpm)
    }

    func setGridOffset(_ seconds: Double) {
        editor.grid.offsetSeconds = seconds.isFinite ? max(0, seconds) : 0
    }

    func setGridOffsetFromPlayhead() {
        setGridOffset(playheadSeconds)
    }

    func setTargetProgram(_ program: Int) {
        guard mixer.entries.contains(where: { $0.program == program }) else { return }

        editor.targetProgram = program
    }

    /// The selection, or everything when nothing is selected; starts only.
    func quantizeSelectionOrAll() {
        guard let document else { return }

        let ids = editor.selection.isEmpty ? Set(document.notes.map(\.id)) : editor.selection

        commit(document.quantize(ids, grid: editor.grid, lengths: false))
    }
}
