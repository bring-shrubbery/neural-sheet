import Foundation
import NeuralSheetCore

/// The Score tab's arrangement rules (arrangement design §5), shared by the Mac's `AppModel` and
/// the iPhone and iPad's `MobileModel`: each changes one part's display as the command says, with
/// the clamps and the defaults in one place. The models read the display, apply one of these and
/// write it back only when it changed.
nonisolated enum ArrangementCommands {
    /// Tab or notation and tab on a part with no template first gives it one, so the switch
    /// works on any part: the template its program suggests (a guitar's or a bass's), or the
    /// guitar's for the rest, in the default tuning. The Template menu changes it afterwards.
    static func setMode(_ mode: PartDisplay.Mode, program: Int, _ display: inout PartDisplay) {
        if mode != .notation, display.tab == nil,
           let template = TabTemplate.template(forProgram: program) ?? TabTemplate.all.first {
            setTab(template: template, preset: template.presets[0], &display)
        }

        display.mode = mode
    }

    /// Semitones, −36…36.
    static func setTransposition(_ semitones: Int, _ display: inout PartDisplay) {
        display.transposition = min(max(semitones, -36), 36)
    }

    /// A template and one of its presets. A part still in notation goes to notation and tab,
    /// and one with no transposition takes the template's customary one.
    static func setTab(template: TabTemplate, preset: TuningPreset, _ display: inout PartDisplay) {
        let hadTab = display.tab != nil
        display.tab = template.setup(preset: preset)
        if display.mode == .notation { display.mode = .both }
        if !hadTab, display.transposition == 0 { display.transposition = template.defaultTransposition }
        display.strings = [:]
    }

    static func clearTab(_ display: inout PartDisplay) {
        display.tab = nil
        display.strings = [:]
        if display.mode != .notation { display.mode = .notation }
    }

    /// One string's open pitch, which makes the tuning custom. Any tuning change drops the
    /// manual string choices, as choosing a preset does: they were made for the old pitches.
    static func setTuning(string: Int, pitch: Int, _ display: inout PartDisplay) {
        guard var tab = display.tab, string >= 0, string < tab.tuning.count else { return }
        tab.tuning[string] = min(max(pitch, 0), 127)
        tab.presetName = nil
        display.tab = tab
        display.strings = [:]
    }

    /// 1…36 frets.
    static func setFrets(_ frets: Int, _ display: inout PartDisplay) {
        guard var tab = display.tab else { return }
        tab.frets = min(max(frets, 1), 36)
        display.tab = tab
    }

    /// The score as the Score tab and the exports see it: the notes with the document's ids
    /// (nil while a run streams), on the editor's grid, in its key, with its chords and markers.
    static func scoreDocument(notes: [NoteEvent], ids: [NoteID?]?, editor: EditorState,
                              arrangement: ScoreArrangement) -> ScoreDocument {
        ScoreDocument.build(notes: notes, ids: ids, grid: editor.grid, key: editor.key, arrangement: arrangement,
                            chords: editor.chords, markers: editor.markers)
    }
}
