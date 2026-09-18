import Foundation
import NeuralSheetCore

/// Where the engine thread leaves each chunk for the main actor's 30 Hz drain (§3.4, §11.5).
///
/// The engine reports once per 5 s of audio, on its own thread; the drain runs at the timer's
/// pace and finds something only at the model's. Keeping the hand-off in a buffer rather than
/// hopping every update onto the main actor keeps the C++ shape: nothing the engine does can touch
/// the notes the piano roll is drawing, and a cancelled or failed run leaves nothing half-applied.
///
/// `@unchecked Sendable`: every field is guarded by `lock`.
nonisolated final class TranscriptionStaging: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [EngineNote] = []
    private var finalizedThrough = 0.0
    private var progress: Float = 0

    /// The engine thread: adds one chunk's notes and moves the frontier and the progress.
    func stage(_ update: EngineUpdate) {
        lock.lock()
        notes.append(contentsOf: update.newNotes)
        finalizedThrough = max(finalizedThrough, update.finalizedThrough)
        progress = max(progress, update.progress)
        lock.unlock()
    }

    /// The main actor: takes everything staged since the last drain. The frontier and the progress
    /// are left as they are, so a drain that finds no notes still reads the latest of each.
    func drain() -> (notes: [EngineNote], finalizedThrough: Double, progress: Float) {
        lock.lock()
        defer { lock.unlock() }

        let drained = notes
        notes = []

        return (drained, finalizedThrough, progress)
    }

    /// Before a run, and after one ends: nothing from the last run may leak into the next.
    func reset() {
        lock.lock()
        notes = []
        finalizedThrough = 0
        progress = 0
        lock.unlock()
    }
}

extension AppModel {
    /// The 30 Hz drain's rate (§11.5).
    private static let drainHz = 30.0

    /// The model's input rate, and with it the least audio a run accepts: one second (§3.4 step 8).
    private static let transcriptionSampleRate = 16000

    // MARK: - Launch

    /// `TranscriptionManager::launchTranscribeJob`, step for step (§3.4).
    func launchTranscription() {
        // 1. Only from `audioLoaded`, and only one run at a time. The Transcribe button hides on
        //    the next state change, so a second click can land while the first run is starting.
        guard state == .audioLoaded, !jobActive, !transcriber.isRunning else { return }

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
        let groups = selectedGroups.map(\.rawValue)

        // 6. Every instrument this run finds is a new one: it starts at unity and unmuted rather
        //    than inheriting a fader from whatever was transcribed before.
        resetMixerSettingsForLaunch()

        // 7.
        transition(to: .processing)

        // 8. At least one second of audio to transcribe; otherwise everything goes, as the C++ has it.
        guard let source, source.mono16k.count >= AppModel.transcriptionSampleRate else {
            clear()
            return
        }

        // 9. The run. GPU is always requested (`nsheet_load(_, true, _)`); there is no setting for
        //    it. `onUpdate` and `completion` arrive on the engine's thread.
        transcription.jobActive = true
        transcription.jobModelPath = modelPath
        startDrainTimer()

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
        transcriber.cancel()
    }

    // MARK: - Drain

    private func startDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = AppModel.repeatingTimer(hz: AppModel.drainHz) { [weak self] in
            self?.drainTranscription()
        }
    }

    private func stopDrainTimer() {
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

        guard !drained.notes.isEmpty || drained.finalizedThrough > transcription.finalizedThrough else { return }

        transcription.rawNotes.append(contentsOf: drained.notes.map(NoteEvent.init(engineNote:)))
        transcription.finalizedThrough = max(transcription.finalizedThrough, drained.finalizedThrough)

        applyPostProcessing()
    }

    /// `_updatePostProcessing`: the raw notes become what is drawn, played and exported.
    ///
    /// Order matters. The synths are created before the notes reach the scheduler, so no note can
    /// arrive at the bank for an instrument that has no player yet; the mixer is applied after
    /// they exist, so its faders land somewhere; and the gains are refreshed after the swap,
    /// because the mix is forced to source-only for as long as the scheduler has no notes (§5.3).
    private func applyPostProcessing() {
        transcription.notes = mergeOverlappingNotesWithSamePitch(transcription.rawNotes)

        for program in Set(notes.map(\.program)).sorted() {
            engine.synthBank.ensureInstrument(program: program)
        }

        refreshMixerEntries()

        engine.synthBank.scheduler.swap(notes: notes)
        engine.refreshGains()
    }

    // MARK: - Completion

    /// `_handleFinishedJob`, on the main actor. The engine has already freed the model.
    private func handleFinished(_ result: Result<[EngineNote], EngineError>) {
        guard jobActive else { return }

        // Dropped before anything below runs: `clear()` and `clearTranscription()` refuse to work
        // while a run owns the notes, and from here on none does.
        transcription.jobActive = false
        stopDrainTimer()

        let modelPath = transcription.jobModelPath
        transcription.jobModelPath = nil

        switch result {
        case let .success(final):
            // Replaces the accumulation rather than extending it: the run's own result is
            // authoritative, and the streamed one is missing any note the model never closed.
            transcription.rawNotes = final.map(NoteEvent.init(engineNote:))
            transcription.finalizedThrough = duration
            transcription.progress = 1
            transcription.cancelLatched = false
            staging.reset()
            applyPostProcessing()
            transition(to: .populated)

        case .failure(.cancelled):
            // Back to where the Transcribe button was, with the audio still loaded: cancelling a
            // run the user misconfigured should not cost them the file as well.
            clearTranscription()

        case let .failure(error):
            let reason = AppModel.failureReason(error, modelPath: modelPath)

            clearTranscription()

            presentError?(
                "Transcription failed.",
                reason.isEmpty
                    ? "The transcription model could not be loaded or run."
                    : "The transcription model could not be loaded or run: \(reason).")
        }
    }

    /// The `<reason>` of the failure dialog: the library's own description, except for a checkpoint
    /// from another release, which is the first place such a file shows up and says what to do.
    private static func failureReason(_ error: EngineError, modelPath: URL?) -> String {
        if error.isUnsupportedVersion, let modelPath {
            return "\(modelPath.lastPathComponent) is for another version of NeuralSheet. "
                + "Delete it from the models folder, then download it again"
        }

        switch error {
        case let .load(_, message), let .transcribe(_, message):
            return message
        case .cancelled:
            return ""
        }
    }
}

extension NoteEvent {
    /// The engine's note as the app's: the same span, pitch and program, with the fixed amplitude
    /// of 100/127 the model gives every note (it predicts no velocity).
    nonisolated init(engineNote note: EngineNote) {
        self.init(startTime: note.onset, endTime: note.offset, pitch: note.pitch, program: note.program)
    }
}
