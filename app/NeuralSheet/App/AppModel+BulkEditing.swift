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

    /// The notes a bulk command acts on: what ``quantizeSelectionOrAll()`` picks.
    private func selectionOrAll(in document: NoteDocument) -> Set<NoteID> {
        editor.selection.isEmpty ? Set(document.notes.map(\.id)) : editor.selection
    }

    // MARK: - Transpose

    /// Edit → Transpose: the melodic notes by `semitones`, the set kept together at the pitch
    /// edges as an arrow-key nudge is; drums never move (editor commands design §2).
    func transposeSelectionOrAll(semitones: Int) {
        guard canBulkEdit, let document, semitones != 0 else { return }

        _ = dragCanceller?()

        let ids = selectionOrAll(in: document).filter { id in document.note(id).map { !$0.note.isDrum } ?? false }
        var batch = document.move(ids, deltaSeconds: 0, deltaSemitones: semitones)
        batch.title = "Transpose"
        commit(batch)
    }

    /// Transpose → By Interval…: asks for −24…+24 semitones, starting from the last answer.
    func transposeByInterval() {
        guard canBulkEdit, let presentNumber else { return }

        presentNumber("Transpose by Interval", "Semitones to move the notes by:", -24...24,
                      lastTransposeSemitones, "semitones") { [weak self] semitones in
            guard let self else { return }

            lastTransposeSemitones = semitones
            transposeSelectionOrAll(semitones: semitones)
        }
    }

    // MARK: - Velocity

    /// Velocity → Scale…: asks for 10…200 %, starting from the last answer.
    func scaleVelocityFromPrompt() {
        guard canBulkEdit, let presentNumber else { return }

        presentNumber("Scale Velocity", "Percentage to scale each velocity by:", 10...200,
                      lastVelocityPercent, "%") { [weak self] percent in
            guard let self else { return }

            lastVelocityPercent = percent
            scaleVelocity(percent: percent)
        }
    }

    /// Each velocity times `percent` / 100, clamped to 1…127 by the document.
    func scaleVelocity(percent: Int) {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()

        let factor = Double(percent) / 100
        commit(document.setVelocities(selectionOrAll(in: document), title: "Scale Velocity") {
            Int((Double($0) * factor).rounded())
        })
    }

    /// Velocity → From Audio: each note's velocity from the take's loudness at its onset, mapped
    /// over the affected notes' range (editor commands design §2). On the main actor: it reads
    /// 800 samples a note, which is quick even for thousands.
    func velocityFromAudio() {
        guard canVelocityFromAudio, let document, let source else { return }

        _ = dragCanceller?()

        let ids = selectionOrAll(in: document)
        let targets = document.notes.filter { ids.contains($0.id) }
        let velocities = OnsetLoudness.velocities(forOnsets: targets.map(\.note.startTime), mono16k: source.mono16k)
        let byID = Dictionary(uniqueKeysWithValues: zip(targets.map(\.id), velocities))

        commit(document.setVelocities(byID, title: "Velocity from Audio"))
    }

    // MARK: - Lengths

    /// Edit → Legato: each note to the next start of its instrument.
    func legatoSelectionOrAll() {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()
        commit(document.legato(selectionOrAll(in: document)))
    }

    /// Edit → Join Notes: same-pitch runs whose gaps are at most 50 ms, or a grid step at the
    /// first note's tempo when snap is on and that is longer (editor commands design §2).
    func joinSelectionOrAll() {
        guard canBulkEdit, let document else { return }

        _ = dragCanceller?()

        let ids = selectionOrAll(in: document)
        let earliest = document.notes.first { ids.contains($0.id) }?.note.startTime ?? playheadSeconds
        let step = editor.snapEnabled ? editor.grid.step(atSeconds: earliest) : 0

        commit(document.join(ids, gap: max(0.05, step)))
    }

    /// Edit → Split at Playhead: every affected note the playhead crosses, in two; the halves
    /// become the selection, and with none crossed nothing happens. The menu does not grey the
    /// item for that: it would have to read the playhead, and the menu bar would be rebuilt on
    /// every frame of playback. The split allocates ids, so its copy of the document is the one
    /// committed on, as Paste's is.
    func splitAtPlayhead() {
        guard canBulkEdit, var document else { return }

        _ = dragCanceller?()

        let (batch, halves) = document.split(selectionOrAll(in: document), at: playheadSeconds)

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
        commit(document.humanize(selectionOrAll(in: document), timing: 0.012, velocity: 8, using: &generator))
    }

    // MARK: - Swing

    /// SWING on the Edit toolbar, as a ratio (0.5…0.75); saved with the project.
    func setSwing(_ ratio: Double) {
        editor.grid.swing = ratio
    }
}
