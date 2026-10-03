import Foundation
import NeuralSheetCore

/// The Edit menu's bulk commands (editor commands design §4): transpose, velocity, legato, join,
/// split and humanize, each on the selection or every note when nothing is selected, as Quantize
/// does, and each one undo step. None auditions: they are bulk edits, and the first note of a
/// whole passage is not what the user wants to hear. And SWING, the grid's swing ratio.
extension AppModel {
    // MARK: - Enablement

    /// The Edit tab, with a document the user may edit: every bulk command needs that much.
    var canBulkEdit: Bool { workspace == .edit && canEdit }

    /// From Audio also needs a take to measure.
    var canVelocityFromAudio: Bool { canBulkEdit && source != nil }

    // MARK: - Transpose

    /// Edit → Transpose: the melodic notes by `semitones`, the set kept together at the pitch
    /// edges as an arrow-key nudge is; drums never move (editor commands design §2).
    func transposeSelectionOrAll(semitones: Int) {
        guard canBulkEdit, let document, semitones != 0 else { return }

        _ = dragCanceller?()

        commit(EditingCommands.transpose(in: document, selection: editor.selection, semitones: semitones))
    }

    /// Transpose → By Interval…: asks for −24…+24 semitones, starting from the last answer.
    func transposeByInterval() {
        guard canBulkEdit, let presentNumber else { return }

        presentNumber(String(localized: "Transpose by Interval", comment: "Edit → Transpose → By Interval…: the alert's title"),
                      String(localized: "Semitones to move the notes by:", comment: "Edit → Transpose → By Interval…: the alert's question"),
                      -24...24, lastTransposeSemitones,
                      String(localized: "semitones", comment: "Edit → Transpose → By Interval…: the unit after the field")) { [weak self] semitones in
            guard let self else { return }

            lastTransposeSemitones = semitones
            transposeSelectionOrAll(semitones: semitones)
        }
    }

    // MARK: - Velocity

    /// Velocity → Scale…: asks for 10…200 %, starting from the last answer.
    func scaleVelocityFromPrompt() {
        guard canBulkEdit, let presentNumber else { return }

        presentNumber(String(localized: "Scale Velocity", comment: "Edit → Velocity → Scale…: the alert's title"),
                      String(localized: "Percentage to scale each velocity by:", comment: "Edit → Velocity → Scale…: the alert's question"),
                      10...200, lastVelocityPercent, "%") { [weak self] percent in
            guard let self else { return }

            lastVelocityPercent = percent
            scaleVelocity(percent: percent)
        }
    }

    /// Each velocity times `percent` / 100, clamped to 1…127 by the document.
    func scaleVelocity(percent: Int) {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()

        commit(EditingCommands.scaleVelocity(in: document, selection: editor.selection, percent: percent))
    }

    /// Velocity → From Audio: each note's velocity from the take's loudness at its onset, mapped
    /// over the affected notes' range (editor commands design §2). On the main actor: it reads
    /// 800 samples a note, which is quick even for thousands.
    func velocityFromAudio() {
        guard canVelocityFromAudio, let document, let source else { return }

        _ = dragCanceller?()

        commit(EditingCommands.velocityFromAudio(in: document, selection: editor.selection, mono16k: source.mono16k))
    }

    // MARK: - Lengths

    /// Edit → Legato: each note to the next start of its instrument.
    func legatoSelectionOrAll() {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.legato(in: document, selection: editor.selection))
    }

    /// Edit → Join Notes: same-pitch runs whose gaps are at most 50 ms, or a grid step at the
    /// first note's tempo when snap is on and that is longer (editor commands design §2).
    func joinSelectionOrAll() {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.join(in: document, editor: editor, playheadSeconds: playheadSeconds))
    }

    /// Edit → Split at Playhead: every affected note the playhead crosses, in two; the halves
    /// become the selection, and with none crossed nothing happens. The menu does not grey the
    /// item for that: it would have to read the playhead, and the menu bar would be rebuilt on
    /// every frame of playback. The split allocates ids, so its copy of the document is the one
    /// committed on, as Paste's is.
    func splitAtPlayhead() {
        guard canBulkEdit, var document else { return }

        _ = dragCanceller?()

        let (batch, halves) = EditingCommands.split(in: &document, selection: editor.selection, at: playheadSeconds)

        guard !batch.isEmpty else { return }

        replaceDocumentAndCommit(document, batch)
        setSelection(halves)
    }

    // MARK: - Humanize

    /// Edit → Humanize: starts within ±12 ms and velocities within ±8, fresh each time, so it can
    /// be applied again; each application is its own undo step.
    func humanizeSelectionOrAll() {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()

        var generator = SystemRandomNumberGenerator()
        commit(EditingCommands.humanize(in: document, selection: editor.selection, using: &generator))
    }

    // MARK: - Swing

    /// SWING on the Edit toolbar, as a ratio (0.5…0.75); saved with the project.
    func setSwing(_ ratio: Double) {
        editor.grid.swing = ratio
    }
}
