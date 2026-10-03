import Foundation
import NeuralSheetCore

/// The roll's commands menu (sub-issue F): the Mac's Edit menu over the shared
/// `EditingCommands`, each on the selection or every note when nothing is selected and each one
/// undo step; Detect, Track Pitch, the versions and Revert to Transcription. The questions the Mac
/// asks in alerts (how many semitones, which percentage, whether to replace) are the screen's.
extension MobileModel {
    // MARK: - Bulk commands

    func quantizeSelectionOrAll() {
        guard canEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.quantize(in: document, editor: editor))
    }

    /// Snap to Scale needs a key.
    var canSnapToScale: Bool { canEdit && editor.key != nil }

    func snapSelectionOrAllToScale() {
        guard canEdit, let document, let batch = EditingCommands.snapToScale(in: document, editor: editor) else { return }

        _ = dragCanceller?()
        commit(batch)
        auditionSelection()
    }

    func transposeSelectionOrAll(semitones: Int) {
        guard canEdit, let document, semitones != 0 else { return }

        _ = dragCanceller?()
        commit(EditingCommands.transpose(in: document, selection: editor.selection, semitones: semitones))
    }

    func scaleVelocity(percent: Int) {
        guard canEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.scaleVelocity(in: document, selection: editor.selection, percent: percent))
    }

    var canVelocityFromAudio: Bool { canEdit && source != nil }

    func velocityFromAudio() {
        guard canVelocityFromAudio, let document, let source else { return }

        _ = dragCanceller?()
        commit(EditingCommands.velocityFromAudio(in: document, selection: editor.selection, mono16k: source.mono16k))
    }

    func legatoSelectionOrAll() {
        guard canEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.legato(in: document, selection: editor.selection))
    }

    func joinSelectionOrAll() {
        guard canEdit, let document else { return }

        _ = dragCanceller?()
        commit(EditingCommands.join(in: document, editor: editor, playheadSeconds: currentPlayheadSeconds))
    }

    /// Every affected note the playhead crosses, in two; the halves become the selection.
    func splitAtPlayhead() {
        guard canEdit, var document else { return }

        _ = dragCanceller?()

        let (batch, halves) = EditingCommands.split(in: &document, selection: editor.selection, at: currentPlayheadSeconds)

        guard !batch.isEmpty else { return }

        replaceDocumentAndCommit(document, batch)
        setSelection(halves)
    }

    func humanizeSelectionOrAll() {
        guard canEdit, let document else { return }

        _ = dragCanceller?()

        var generator = SystemRandomNumberGenerator()
        commit(EditingCommands.humanize(in: document, selection: editor.selection, using: &generator))
    }

    /// The engine's playhead while it plays, the model's when it stands.
    private var currentPlayheadSeconds: Double {
        engine.isPlaying ? engine.playheadSeconds : playheadSeconds
    }

    // MARK: - Detect

    /// Detect needs a take; the key and the chords also need melodic notes, and are left alone
    /// without them.
    var canDetect: Bool { source != nil && !isDetecting && run == nil }

    /// Whether Detect would throw away something shaped by hand -- a tempo change, a meter other
    /// than 4/4, or edited chords -- so the screen asks first, as the Mac does.
    var detectReplacesEdits: Bool {
        let grid = editor.grid

        return grid.segments.count > 1 || grid.segments.contains { $0.timeSignature != .common }
            || (editor.chordsEdited && !editor.chords.isEmpty)
    }

    /// The Mac's Detect: the tempo map and the downbeat from the take, found off the main actor;
    /// then the key from the notes, then the chords on the new bars.
    func detect() {
        guard canDetect, let source else { return }

        isDetecting = true

        let mono = source.mono16k
        let meter = editor.grid.timeSignature

        Task.detached(priority: .userInitiated) { [weak self] in
            let estimate = TempoEstimator.estimate(mono16k: mono, meter: meter)

            await self?.detectionDidFinish(estimate, for: source)
        }
    }

    private func detectionDidFinish(_ estimate: TempoEstimate?, for analysed: SourceAudio) {
        isDetecting = false

        guard source === analysed else { return }

        guard let estimate else {
            alert = MobileAlert(title: String(localized: "Could not detect a tempo.", comment: "Alert title: Detect found no tempo"),
                                message: String(localized: "The take is too short or has no clear beat.", comment: "Alert body: Detect found no tempo"))
            return
        }

        var editor = self.editor
        editor.grid.replaceMap(estimate.segments, offsetSeconds: estimate.downbeatSeconds)

        if let document {
            if let key = KeyEstimator.estimate(notes: document.events) {
                editor.key = key
            }

            if document.events.contains(where: { !$0.isDrum }) {
                editor.chords = EditingCommands.detectedChords(in: document, editor: editor, duration: duration)
                editor.chordsEdited = false
            }
        }

        guard editor != self.editor else { return }

        let before = self.editor
        self.editor = editor
        registerDetectionUndo(before: before)
    }

    /// The map, the key and the chords are project state, not note edits; on the Mac they are not
    /// undoable. Here the change must reach the undo manager for the document to save it, so it is
    /// registered, and Undo puts them back.
    private func registerDetectionUndo(before: EditorState) {
        guard let undoManager else { return }

        undoManager.registerUndo(withTarget: self) { model in
            let after = model.editor
            model.editor.grid = before.grid
            model.editor.key = before.key
            model.editor.chords = before.chords
            model.editor.chordsEdited = before.chordsEdited
            model.registerDetectionUndo(before: after)
        }
        undoManager.setActionName(String(localized: "Detect", comment: "Undo title: the tempo map, key and chords Detect found"))
    }

    // MARK: - Track Pitch

    var canTrackPitch: Bool { canEdit && source != nil && !isTrackingPitch }

    /// The Mac's Track Pitch: the curves measured off the main actor and landed as one batch,
    /// each only on a note that still has the start, end and pitch it was measured at.
    func trackPitch() {
        guard canTrackPitch, let document, let source else { return }

        _ = dragCanceller?()

        let targets = EditingCommands.pitchTrackingTargets(in: document, selection: editor.selection)

        guard !targets.isEmpty else { return }

        let samples = source.mono16k
        isTrackingPitch = true

        pitchJob = Task.detached { [weak self] in
            let curves = PitchTracker.track(notes: targets, mono16k: samples, isCancelled: { Task.isCancelled })

            await self?.finishPitchTracking(curves, measured: targets)
        }
    }

    /// A new take or new notes: the curves being measured are for notes that are going.
    func cancelPitchTracking() {
        pitchJob?.cancel()
        pitchJob = nil

        if isTrackingPitch {
            isTrackingPitch = false
        }
    }

    private func finishPitchTracking(_ curves: [NoteID: [Float]?], measured: [EditableNote]) {
        // Cancelled by a new take or new notes, which have already cleared the job.
        guard !Task.isCancelled else { return }

        pitchJob = nil
        isTrackingPitch = false

        guard let document else { return }

        commit(EditingCommands.landPitchCurves(curves, measured: measured, in: document))
    }

    // MARK: - Versions

    var canUseVersions: Bool { document != nil && run == nil }

    var versionRows: [VersionRow] {
        EditingCommands.versionRows(rawNotes: rawNotes, versions: versions)
    }

    func defaultVersionName() -> String {
        EditingCommands.defaultVersionName(existing: versions.count)
    }

    /// The document's notes as a new version, last in the list; a blank name takes the default.
    /// Not an edit of the notes, but of the project: registered so the document saves.
    func saveVersion(named name: String) {
        guard canUseVersions, let document else { return }

        let before = projectSnapshot()
        versions.append(EditingCommands.newVersion(named: name, document: document, existing: versions.count))
        registerUndo(String(localized: "Save Version", comment: "Undo title: a version saved"), before: before)
    }

    /// The version's notes in place of the document's, as one undoable edit.
    func restoreVersion(id: UUID) {
        guard canEdit, var document,
            let version = EditingCommands.version(id: id, rawNotes: rawNotes, versions: versions)
        else { return }

        _ = dragCanceller?()
        replaceDocumentAndCommit(document, EditingCommands.restore(version, in: &document))
    }

    /// Compare With: the version ghosted behind the roll, or none.
    func compare(with id: UUID?) {
        guard let id else {
            comparedVersion = nil
            return
        }

        guard canUseVersions, comparedVersion?.id != id else { return }

        comparedVersion = EditingCommands.version(id: id, rawNotes: rawNotes, versions: versions)
    }

    var comparisonSummary: VersionComparisonSummary? {
        EditingCommands.comparisonSummary(document: document, comparedVersion: comparedVersion)
    }

    /// Show Differences: the notes with no counterpart in the compared version, selected.
    func showDifferences() {
        guard canEdit, let document, let comparedVersion else { return }

        _ = dragCanceller?()
        setSelection(EditingCommands.differences(in: document, against: comparedVersion))
    }

    // MARK: - Revert

    var canRevertToTranscription: Bool { canEdit && (document?.isEdited ?? false) }

    /// Back to the model's own output (the screen asks first). Undoable here, as a run landing
    /// is: the edited document, with its history, is what Undo puts back.
    func revertToTranscription() {
        guard canRevertToTranscription else { return }

        _ = dragCanceller?()

        let before = projectSnapshot()
        installDocument(rawNotes: rawNotes)
        registerUndo(String(localized: "Revert to Transcription", comment: "Undo title: the edits thrown away"), before: before)
    }
}
