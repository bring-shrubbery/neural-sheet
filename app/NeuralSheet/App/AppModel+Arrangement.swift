import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The Score tab's arrangement commands (arrangement design §5): every write to
/// `arrangement` goes through here, so the pruning and the defaults live in one place.
extension AppModel {
    private func updatePart(_ program: Int, _ change: (inout PartDisplay) -> Void) {
        var display = arrangement.display(for: program)
        change(&display)

        if arrangement.parts[program] != display {
            arrangement.parts[program] = display
        }
    }

    /// Tab or notation and tab on a part with no template first gives it one (`ArrangementCommands`).
    func setPartMode(_ mode: PartDisplay.Mode, program: Int) {
        updatePart(program) { ArrangementCommands.setMode(mode, program: program, &$0) }
    }

    func setPartClef(_ clef: ClefChoice, program: Int) {
        updatePart(program) { $0.clef = clef }
    }

    /// Semitones, −36…36.
    func setPartTransposition(_ semitones: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setTransposition(semitones, &$0) }
    }

    /// A template and one of its presets (`ArrangementCommands.setTab`).
    func setPartTab(template: TabTemplate, preset: TuningPreset, program: Int) {
        updatePart(program) { ArrangementCommands.setTab(template: template, preset: preset, &$0) }
    }

    func clearPartTab(program: Int) {
        updatePart(program) { ArrangementCommands.clearTab(&$0) }
    }

    /// One string's open pitch, which makes the tuning custom (`ArrangementCommands.setTuning`).
    func setPartTuning(string: Int, pitch: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setTuning(string: string, pitch: pitch, &$0) }
    }

    func setPartFrets(_ frets: Int, program: Int) {
        updatePart(program) { ArrangementCommands.setFrets(frets, &$0) }
    }

    func setPartHidden(_ hidden: Bool, program: Int) {
        updatePart(program) { $0.isHidden = hidden }
    }

    /// A manual string for one note, or nil for the automatic choice.
    func setString(_ string: Int?, program: Int, id: NoteID) {
        updatePart(program) { display in
            if let string {
                display.strings[id] = string
            } else {
                display.strings[id] = nil
            }
        }
    }

    func selectTabNote(program: Int, id: NoteID) {
        selectedTabNote = (program, id)
    }

    func deselectTabNote() {
        selectedTabNote = nil
    }

    /// ↑ / ↓ in the Score tab: the selected note a string up or down, clamped to the template.
    func moveSelectedTabString(by delta: Int) {
        guard let selected = selectedTabNote, let tab = arrangement.display(for: selected.program).tab,
              let current = currentString(program: selected.program, id: selected.id) else { return }

        setString(min(max(current + delta, 0), tab.tuning.count - 1), program: selected.program, id: selected.id)
    }

    /// The string a note is on now: the manual choice, else where the automatic placement put
    /// it, read off a fresh score.
    func currentString(program: Int, id: NoteID) -> Int? {
        if let manual = arrangement.display(for: program).strings[id] { return manual }

        let score = scoreDocument()
        guard let part = score.parts.first(where: { $0.program == program }), let tab = part.tab else { return nil }

        for measure in tab.measures {
            for piece in measure.pieces {
                if let note = piece.notes.first(where: { $0.id == id }) { return note.placement?.string }
            }
        }

        return nil
    }

    /// The score as the Score tab and the exports see it.
    func scoreDocument() -> ScoreDocument {
        let ids = document?.notes.map { Optional($0.id) }
        return ArrangementCommands.scoreDocument(notes: notes, ids: ids, editor: editor, arrangement: arrangement)
    }

    /// Drops every manual string choice and the tab selection: for a document whose ids start
    /// over (see `installDocument`), where pruning against the new ids would keep the wrong ones.
    func dropStringChoices() {
        for (program, display) in arrangement.parts where !display.strings.isEmpty {
            arrangement.parts[program]?.strings = [:]
        }

        selectedTabNote = nil
    }

    /// Drops manual string choices for notes the document no longer has. After every commit.
    func pruneStringChoices() {
        guard let document else { return }

        for (program, display) in arrangement.parts where !display.strings.isEmpty {
            let kept = display.strings.filter { document.contains($0.key) }
            if kept.count != display.strings.count {
                arrangement.parts[program]?.strings = kept
            }
        }

        if let selected = selectedTabNote, !document.contains(selected.id) {
            selectedTabNote = nil
        }
    }

    func setSheet(_ sheet: SheetMetadata) {
        if arrangement.sheet != sheet { arrangement.sheet = sheet }
    }

    func setScoreLayout(_ layout: ScoreLayoutMode) {
        if arrangement.layout != layout { arrangement.layout = layout }
    }

    func setPageSize(_ size: PageSize) {
        if arrangement.pageSize != size { arrangement.pageSize = size }
    }

    // MARK: - Export PDF

    /// File → Export PDF…: the pages, whatever the tab shows, through a save panel titled
    /// "Export PDF" in the Music folder.
    func exportPDF() {
        guard canExport else { return }

        // A PDF context that cannot be made is as much a failure as a file that cannot be written.
        guard let data = ExportCommands.pdfData(document: scoreDocument(), arrangement: arrangement, takeName: droppedFileName) else {
            showError(AppModel.errorTitle, String(localized: "Could not write the PDF file.", comment: "Alert body: File → Export PDF… failed"))
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export PDF", comment: "File → Export PDF…'s save panel")
        panel.message = String(localized: "Export PDF", comment: "File → Export PDF…'s save panel")
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = ExportCommands.pdfFileName(takeName: droppedFileName)
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(AppModel.errorTitle, String(localized: "Could not write the PDF file.", comment: "Alert body: File → Export PDF… failed"))
        }
    }
}
