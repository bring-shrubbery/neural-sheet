import Foundation
import NeuralSheetCore

/// A run of the model over the marked range alone (region design §4.3): the slice with its
/// context, the same engine as the main run, and one "Re-transcribe" batch when it lands.
/// Nothing is applied before completion, so a cancel leaves the document exactly as it was and
/// the model's raw notes are never touched: Revert to Transcription still means the original run.
extension AppModel {
    struct RegionJob: Equatable {
        var range: Range<Double>
        /// The run's constraint; empty is Automatic.
        var groups: [InstrumentGroup]
        var slice: RegionSlice
        /// For the unsupported-version wording of the failure dialog.
        var modelPath: URL
        var progress: Float = 0
        /// From the cancel click until the engine acknowledges it at the next chunk boundary.
        var cancelLatched = false
    }

    /// The Re-transcribe button: a range, a document, a checkpoint, and no run of either kind.
    var canRetranscribe: Bool {
        state == .populated && document != nil && regionJob == nil && !jobActive
            && editor.range != nil && modelSize != nil
    }

    // MARK: - Launch

    func retranscribe(range: Range<Double>, groups: [InstrumentGroup]) {
        guard state == .populated, document != nil, regionJob == nil, !jobActive, !transcriber.isRunning else { return }
        guard let size = modelSize, let modelPath = modelStore.installedPath(for: size) else { return }
        guard let source, let slice = RegionSlice(range: range, duration: duration) else { return }

        let sampleRange = slice.sampleRange(sampleCount: source.mono16k.count)

        guard !sampleRange.isEmpty else { return }

        // A drag in progress would commit against a document about to change under it, and the
        // note card follows the selection out.
        _ = dragCanceller?()
        deselectAll()
        editor.retranscribeGroups = groups
        regionJob = RegionJob(range: range, groups: groups, slice: slice, modelPath: modelPath)

        let samples = Array(source.mono16k[sampleRange])

        // `onUpdate` and `completion` arrive on the engine's thread. A chunk is 5 s of audio, so
        // hopping each progress value onto the main actor is a handful of tasks per run; there is
        // no staging and no drain, because nothing is applied until the end.
        transcriber.run(
            modelPath: modelPath,
            groups: groups.map(\.rawValue),
            samples16k: samples,
            onUpdate: { [weak self] update in
                let progress = update.progress

                Task { @MainActor in
                    guard let self, var job = self.regionJob else { return }

                    job.progress = max(job.progress, progress)
                    self.regionJob = job
                }

                return true
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.handleRegionFinished(result)
                }
            })
    }

    /// The cross on the progress group. Latched in the UI; the engine sees it at the next chunk.
    func cancelRegionTranscription() {
        guard regionJob != nil else { return }

        regionJob?.cancelLatched = true
        transcriber.cancel()
    }

    // MARK: - Completion

    /// On the main actor. A job cleared by a clear or a close ignores its completion.
    private func handleRegionFinished(_ result: Result<[EngineNote], EngineError>) {
        guard let job = regionJob else { return }

        regionJob = nil

        switch result {
        case let .success(engineNotes):
            guard var document else { return }

            let shifted = engineNotes.map { engineNote -> NoteEvent in
                var note = NoteEvent(engineNote: engineNote)
                note.startTime += job.slice.start
                note.endTime += job.slice.start

                return note
            }

            let batch = document.replace(range: job.range, with: mergeOverlappingNotesWithSamePitch(shifted))
            replaceDocumentAndCommit(document, batch)
            // The result is the selection: audition it, nudge it, or undo it at once.
            setSelection(Set(batch.inserted.map(\.id)))

        case .failure(.cancelled):
            break

        case let .failure(error):
            let reason = AppModel.failureReason(error, modelPath: job.modelPath)

            showError(
                "Transcription failed.",
                reason.isEmpty
                    ? "The transcription model could not be loaded or run."
                    : "The transcription model could not be loaded or run: \(reason).")
        }
    }

    // MARK: - The popup's instrument choice

    /// Empty is Automatic.
    func setRetranscribeGroups(_ groups: [InstrumentGroup]) {
        let normalised = AppModel.normalised(groups)

        if editor.retranscribeGroups != normalised {
            editor.retranscribeGroups = normalised
        }
    }

    func toggleRetranscribeGroup(_ group: InstrumentGroup) {
        var groups = editor.retranscribeGroups ?? []

        if groups.contains(group) {
            groups.removeAll { $0 == group }
        } else {
            groups.append(group)
        }

        setRetranscribeGroups(groups)
    }
}
