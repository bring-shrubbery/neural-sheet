import Foundation
import NeuralSheetCore

/// The Score screen's side of the model (sub-issue G): the score document it draws, and the
/// arrangement commands its part and sheet sheets send -- the Mac's `AppModel+Arrangement` over
/// the shared `ArrangementCommands`, writing `arrangement` only when it changed.
///
/// The arrangement is project state, not a note edit, and on the Mac it is not undoable. Here a
/// change must reach the undo manager for the document to save it (as Detect's does), so each is
/// registered, and Undo puts the arrangement back.
extension MobileModel {
    /// The score as the Score screen sees it: the document's notes with their ids, or while a run
    /// streams what it has found so far, without.
    func scoreDocument() -> ScoreDocument {
        let notes = document?.events ?? streamedNotes
        let ids = document?.notes.map { Optional($0.id) }

        return ArrangementCommands.scoreDocument(notes: notes, ids: ids, editor: editor, arrangement: arrangement)
    }

    // MARK: - A part's display

    func setPartMode(_ mode: PartDisplay.Mode, program: Int) {
        updatePart(program) { ArrangementCommands.setMode(mode, program: program, &$0) }
    }

    func setPartClef(_ clef: ClefChoice, program: Int) {
        updatePart(program) { $0.clef = clef }
    }

    func setPartTransposition(_ semitones: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setTransposition(semitones, &$0) }
    }

    func setPartTab(template: TabTemplate, preset: TuningPreset, program: Int) {
        updatePart(program) { ArrangementCommands.setTab(template: template, preset: preset, &$0) }
    }

    func clearPartTab(program: Int) {
        updatePart(program) { ArrangementCommands.clearTab(&$0) }
    }

    func setPartTuning(string: Int, pitch: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setTuning(string: string, pitch: pitch, &$0) }
    }

    func setPartFrets(_ frets: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setFrets(frets, &$0) }
    }

    func setPartHidden(_ hidden: Bool, program: Int) {
        updatePart(program) { $0.isHidden = hidden }
    }

    // MARK: - The sheet

    func setSheet(_ sheet: SheetMetadata) {
        var arrangement = arrangement
        arrangement.sheet = sheet
        setArrangement(arrangement)
    }

    func setScoreLayout(_ layout: ScoreLayoutMode) {
        var arrangement = arrangement
        arrangement.layout = layout
        setArrangement(arrangement)
    }

    func setPageSize(_ size: PageSize) {
        var arrangement = arrangement
        arrangement.pageSize = size
        setArrangement(arrangement)
    }

    // MARK: - Writes

    private func updatePart(_ program: Int, _ change: (inout PartDisplay) -> Void) {
        var display = arrangement.display(for: program)
        change(&display)

        guard arrangement.parts[program] != display else { return }

        var arrangement = arrangement
        arrangement.parts[program] = display
        setArrangement(arrangement)
    }

    private func setArrangement(_ new: ScoreArrangement) {
        guard new != arrangement else { return }

        let before = arrangement
        arrangement = new
        registerArrangementUndo(before: before)
    }

    private func registerArrangementUndo(before: ScoreArrangement) {
        guard let undoManager else { return }

        undoManager.registerUndo(withTarget: self) { model in
            let after = model.arrangement
            model.arrangement = before
            model.registerArrangementUndo(before: after)
        }
        undoManager.setActionName(String(localized: "Score Layout", comment: "Undo title: a change to how the score shows the parts or the sheet"))
    }
}
