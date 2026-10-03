import Foundation
import NeuralSheetCore

extension AppModel {
    /// Everything the transcription pipeline writes, as one value: `AppModel+Transcription.swift`
    /// is the only writer, and the read-only members below are what everyone else sees.
    struct TranscriptionState: Equatable {
        /// The model's own output accumulated across chunks; `notes` is derived from it.
        var rawNotes: [NoteEvent] = []
        /// The post-processed notes: what the piano roll draws, the synth plays, the export writes.
        var notes: [NoteEvent] = []
        /// Seconds: every note ending before this has been reported (the decode frontier).
        var finalizedThrough: Double = 0
        /// 0…1 while processing, 1 once populated.
        var progress: Float = 0
        /// True from the cancel click until the engine acknowledges it at the next chunk boundary.
        var cancelLatched = false
        /// True from `transcriber.run` until its completion has been handled on the main actor.
        var jobActive = false
        /// The checkpoint the run in flight loaded, for the unsupported-version message.
        var jobModelPath: URL?
        /// "Transcribe" or "Stems": what the run in flight is, for the automatic version its
        /// landing saves first (versions design §2).
        var jobRunName: String?
    }

    /// The post-processed notes: what the piano roll draws, what the synth plays, what is exported.
    var notes: [NoteEvent] { transcription.notes }

    /// Seconds: every note ending before this has been reported (the decode frontier).
    var finalizedThrough: Double { transcription.finalizedThrough }

    /// 0…1 while processing, 1 once populated.
    var transcriptionProgress: Float { transcription.progress }

    /// True from the cancel click until the engine acknowledges it at the next chunk boundary. The
    /// progress group dims on it (§3.4).
    var cancelLatched: Bool { transcription.cancelLatched }

    /// True while a run owns the notes: from `transcriber.run` until its completion has landed.
    var jobActive: Bool { transcription.jobActive }

    /// The 30 Hz drain's rate (§11.5).
    private static let drainHz = 30.0

    /// The model's input rate, and with it the least audio a run accepts: one second (§3.4 step 8).
    private static let transcriptionSampleRate = 16000

    // MARK: - Launch

    /// The Transcribe button. A transcription that has been edited is asked about first (§3.5).
    func launchTranscription() {
        guard state == .audioLoaded, importJob == nil else { return }

        confirmDiscardingEdits(String(localized: "The transcription has been edited. Transcribing again will throw the edits away.",
                                      comment: "Alert body: transcribing over an edited transcription")) { [weak self] in
            self?.launchTranscriptionNow()
        }
    }

    /// `TranscriptionManager::launchTranscribeJob`, step for step (§3.4).
    private func launchTranscriptionNow() {
        // 1. Only from `audioLoaded`, and only one run at a time. The Transcribe button hides on
        //    the next state change, so a second click can land while the first run is starting.
        guard state == .audioLoaded, !jobActive, !transcriber.isRunning, stemsExport == nil else { return }

        // 2. The stored size is a preference: when that checkpoint is missing and another is
        //    there, the run uses the one that is there. None at all aborts silently — the model
        //    panel's next poll replaces the button.
        guard let size = modelSize, let modelPath = modelStore.installedPath(for: size) else { return }

        // 3. Armed before the Processing state is published: that state is what makes the cancel
        //    button live. `TranscriptionEngine.run` clears its own cancel flag as it starts, and
        //    this whole launch is one synchronous main-actor call, so no click can fall between
        //    the state going up and the run beginning — but the latch and the staging are cleared
        //    here regardless, before anything is visible.
        staging.reset()

        // 4. Nothing is transcribed yet, and the piano roll is about to start drawing what arrives.
        transcription = TranscriptionState()

        // 5. The selection is snapshotted here; the run only ever sees the copy.
        let groups = TranscriptionPlan.passes(selected: selectedGroups, stems: false)[0].engineGroups

        // 6. Every instrument this run finds is a new one: it starts at unity and unmuted rather
        //    than inheriting a fader from whatever was transcribed before.
        resetMixerSettingsForLaunch()

        // 7.
        transition(to: .processing)

        // 8. At least one second of audio to transcribe; otherwise everything goes, as the C++ has it.
        guard let source, source.mono16k.count >= AppModel.transcriptionSampleRate else {
            clearNow()
            return
        }

        // 9. The run. GPU is always requested (`nsheet_load(_, true, _)`); there is no setting for
        //    it. `onUpdate` and `completion` arrive on the engine's thread.
        transcription.jobActive = true
        transcription.jobModelPath = modelPath
        startDrainTimer()

        // With Stems on and the weights installed, the separator first and the engine four
        // times after (stem separation design §5); the same state, staging and drain. The run's
        // name is what its landing calls the version it saves first (versions design §2).
        let stems = settings.separateStems ? modelStore.installedPath(for: .stems) : nil
        transcription.jobRunName = stems != nil
            ? String(localized: "Stems", comment: "A version's name: \"Before Stems — 14:02\", saved before a stems run")
            : String(localized: "Transcribe", comment: "A version's name: \"Before Transcribe — 14:02\", saved before a run")

        if let stemsPath = stems {
            launchStemsRun(modelPath: modelPath, stemsPath: stemsPath, source: source)
            return
        }

        let staging = self.staging

        transcriber.run(
            modelPath: modelPath,
            groups: groups,
            samples16k: source.mono16k,
            onUpdate: { update in
                staging.stage(update)
                // Cancellation goes through `cancel()`, which the engine checks itself.
                return true
            },
            completion: { [weak self] result in
                guard let self else { return }

                Task { @MainActor in
                    self.handleFinished(result)
                }
            })
    }

    /// The status-bar cross. Latched in the UI, because the engine only sees it at the next chunk
    /// boundary; pressing it again is harmless.
    func cancelTranscription() {
        guard state == .processing, jobActive else { return }

        transcription.cancelLatched = true

        if stemsJob != nil {
            cancelStemsRun()
        } else {
            transcriber.cancel()
        }
    }

    // MARK: - Drain

    private func startDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = AppModel.repeatingTimer(hz: AppModel.drainHz) { [weak self] in
            self?.drainTranscription()
        }
    }

    func stopDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    /// 30 Hz while a run is in flight. Gated on the drain having something, so the post-processing
    /// runs at the model's pace — once per 5 s of audio — rather than at the timer's.
    private func drainTranscription() {
        guard jobActive else { return }

        let drained = staging.drain()

        if drained.progress != transcription.progress {
            transcription.progress = drained.progress
        }

        guard drained.advances(past: transcription.finalizedThrough) else { return }

        transcription.rawNotes.append(contentsOf: drained.rawNotes)
        transcription.finalizedThrough = max(transcription.finalizedThrough, drained.finalizedThrough)

        applyPostProcessing()
    }

    /// `_updatePostProcessing`: the raw notes become what is drawn, played and exported. While a
    /// run streams there is no document; the merge is the whole post-processing.
    private func applyPostProcessing() {
        transcription.notes = TranscriptionRun.streamedNotes(transcription.rawNotes)
        publishNotes()
    }

    /// Order matters. The synths are created before the notes reach the scheduler, so no note can
    /// arrive at the bank for an instrument that has no player yet; the mixer is applied after
    /// they exist, so its faders land somewhere; and the gains are refreshed after the swap,
    /// because the mix is forced to source-only for as long as the scheduler has no notes (§5.3).
    func publishNotes() {
        for program in Set(notes.map(\.program)).sorted() {
            engine.synthBank.ensureInstrument(program: program)
        }

        refreshMixerEntries()

        engine.synthBank.scheduler.swap(notes: notes)
        engine.refreshGains()
    }

    // MARK: - Completion

    /// `_handleFinishedJob`, on the main actor. The engine has already freed the model. Also
    /// where a stems run lands, with its four results as one.
    func handleFinished(_ result: Result<[EngineNote], EngineError>) {
        guard jobActive else { return }

        // Dropped before anything below runs: `clear()` and `clearTranscription()` refuse to work
        // while a run owns the notes, and from here on none does.
        transcription.jobActive = false
        stopDrainTimer()

        let modelPath = transcription.jobModelPath
        transcription.jobModelPath = nil
        let runName = transcription.jobRunName ?? String(localized: "Transcribe", comment: "A version's name: \"Before Transcribe — 14:02\", saved before a run")
        transcription.jobRunName = nil

        switch result {
        case let .success(final):
            // Replaces the accumulation rather than extending it: the run's own result is
            // authoritative (the streamed one is missing any note the model never closed), and
            // it becomes the editable document. The After transcription settings apply here and
            // not to the stream: the roll shows what the model said, the landing what is kept.
            // The notes it replaces are saved as a version first (versions design §2).
            saveVersionBeforeRun(runName)
            landTranscription(TranscriptionRun.landing(final, settings: settings))

        case .failure(.cancelled):
            // Back to where the Transcribe button was, with the audio still loaded: cancelling a
            // run the user misconfigured should not cost them the file as well.
            clearTranscriptionNow()

        case let .failure(error):
            failRun(reason: TranscriptionRun.failureReason(error, modelPath: modelPath))
        }
    }

    /// Notes become the transcription: the whole take finalised, the document made, `populated`.
    /// A finished run's landing, and an imported MIDI file's on an untranscribed take (MIDI
    /// import design §2), which is why it is not inside ``handleFinished(_:)``.
    func landTranscription(_ notes: [NoteEvent]) {
        transcription.finalizedThrough = duration
        transcription.progress = 1
        transcription.cancelLatched = false
        staging.reset()
        installDocument(rawNotes: notes)
        transition(to: .populated)
    }

    /// Ends the run with the failure dialog. Also where a stems run lands when the separation
    /// failed before the engine was reached, so there is no `EngineError` to carry its words;
    /// the teardown above is repeated for that caller and is idempotent.
    func failRun(reason: String) {
        transcription.jobActive = false
        stopDrainTimer()
        transcription.jobModelPath = nil

        clearTranscriptionNow()

        showError(TranscriptionRun.failedTitle, TranscriptionRun.failedBody(reason))
    }
}
