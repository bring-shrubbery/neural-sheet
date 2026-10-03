import AppKit
import NeuralSheetCore

/// The container's part in VoiceOver (a11y design §2): it names the timeline, hands each band
/// what it reads from the model -- the playhead, the level, the grid -- and answers the roll's
/// note actions through the same `AppModel` commands a click or a key uses.
extension TimelineContainerView: RollAccessibilityHandler {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        String(localized: "Timeline", comment: "VoiceOver: the block holding the waveform, the ruler, the keyboard and the piano roll")
    }

    /// Called once from `init`, after the bands exist.
    func installAccessibility() {
        roll.accessibilityHandler = self
        ruler.accessibilityPlayhead = { [weak self] in self?.model.playheadSeconds ?? 0 }
        waveform.accessibilityLevel = { [weak self] in self?.model.masterLevelDb ?? MeterScale.minDb }
        keyboard.onAccessibilityScroll = { [weak self] semitones in self?.scrollPitch(bySemitones: semitones) }
    }

    // MARK: - RollAccessibilityHandler

    var rollAccessibilityGrid: TempoGrid { model.editor.grid }

    var rollAccessibilityEditing: Bool { mode == .edit && model.canEdit }

    func rollAccessibilitySeek(_ seconds: Double) {
        seek(toSeconds: seconds)
    }

    /// As a click on the note: it alone is selected, and heard.
    func rollAccessibilitySelect(_ id: NoteID) {
        model.setSelection([id])
        model.auditionSelection()
    }

    func rollAccessibilityDelete(_ id: NoteID) {
        model.setSelection([id])
        model.deleteSelection()
    }

    /// As the arrow keys move the selection, the note selected first if it was not.
    func rollAccessibilityMove(_ id: NoteID, steps: Int, semitones: Int) {
        if !model.editor.selection.contains(id) {
            model.setSelection([id])
        }

        model.nudgeSelection(steps: steps, semitones: semitones)
    }

    /// As a right-click on the note: selected, then its card at the note.
    func rollAccessibilityOpenCard(_ id: NoteID, at windowPoint: CGPoint) {
        model.setSelection([id])
        editController?.showNoteCard(at: windowPoint)
    }
}
