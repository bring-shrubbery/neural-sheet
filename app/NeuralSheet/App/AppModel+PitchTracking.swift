import Foundation
import NeuralSheetCore

/// Pitch curves in the app (pitch curves design §4): Edit → Track Pitch, which measures the
/// curves off the main actor and lands them as one undoable edit, and View → Show Pitch Curves.
extension AppModel {
    // MARK: - Setting

    /// View → Show Pitch Curves: the roll draws each tracked note's curve. Remembered across
    /// launches in the global settings.
    var showsPitchCurves: Bool {
        get { settings.showsPitchCurves }
        set { settings.showsPitchCurves = newValue }
    }

    // MARK: - Track Pitch

    /// The Edit tab, a take to measure, and neither a region run (which `canBulkEdit` already
    /// refuses) nor another Track Pitch in flight.
    var canTrackPitch: Bool { canBulkEdit && source != nil && pitchJob == nil }

    /// Edit → Track Pitch (⌥⌘P): every melodic note in the selection, or every one with nothing
    /// selected, measured from the take's mono 16 kHz copy in a detached task (design §2,
    /// Threading). The take's samples are immutable, and the notes are a copy, so nothing the
    /// task reads can change under it.
    ///
    /// Edits made while it runs are allowed: the landing applies a curve only to a note that
    /// still exists with the start, end and pitch it was measured at. A clear cancels the task,
    /// and a cancelled task lands nothing.
    func trackPitch() {
        guard canTrackPitch, let document, let source else { return }

        _ = dragCanceller?()

        let targets = EditingCommands.pitchTrackingTargets(in: document, selection: editor.selection)

        guard !targets.isEmpty else { return }

        let samples = source.mono16k

        pitchJob = Task.detached { [weak self] in
            let curves = PitchTracker.track(notes: targets, mono16k: samples, isCancelled: { Task.isCancelled })

            await self?.finishPitchTracking(curves, measured: targets)
        }
    }

    /// Main actor, still inside the task, so `Task.isCancelled` is the job's own: a clear has
    /// been and gone and the document it measured is not this one. Cancellation and this check
    /// both run on the main actor, so no clear can fall between them.
    private func finishPitchTracking(_ curves: [NoteID: [Float]?], measured: [EditableNote]) {
        guard !Task.isCancelled else { return }

        pitchJob = nil

        guard let document else { return }

        commit(EditingCommands.landPitchCurves(curves, measured: measured, in: document))
    }
}
