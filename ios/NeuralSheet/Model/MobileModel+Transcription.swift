import Foundation
import NeuralSheetCore

/// A transcription run over the document's take (sub-issue D): the engine over the take, or the
/// separator and then the engine once per stem, exactly as the Mac's `AppModel+Transcription` and
/// `+Stems` run it -- the same passes and instruments (`TranscriptionPlan`), the same staging and
/// stream (`TranscriptionRun`), the same landing filter. Around it, what a phone needs: a
/// background task and a Live Activity (`RunSupport`), and a pause between chunks while the device
/// is hot (`ThermalGate`).
extension MobileModel {
    /// Where the run in flight is, for the screen and the Live Activity.
    struct RunState: Equatable {
        enum Phase: Equatable {
            case separating
            /// The take itself (nil), or one stem.
            case transcribing(stem: Int?)
        }

        var phase: Phase
        /// 0…1 over the whole run.
        var progress: Float = 0
        /// Seconds: every note ending before this has been reported.
        var finalizedThrough: Double = 0
        /// Held between chunks until the device cools.
        var paused = false
        /// True from the Cancel tap until the engine acknowledges it at the next chunk.
        var cancelLatched = false
        let startedAt: Date
        /// "Transcribe" or "Stems": the name of the version the landing saves first.
        let runName: String
    }

    /// The run's outcome, as the main actor lands it.
    enum RunOutcome: Sendable {
        case success([EngineNote])
        case cancelled
        case failed(reason: String)
    }

    /// The 30 Hz drain's period (§11.5).
    private static let drainInterval = Duration.milliseconds(33)

    var isRunning: Bool { run != nil }

    /// What the Transcribe button needs: a take of a second or more, a transcription model, and
    /// nothing else under way.
    var canTranscribe: Bool {
        guard run == nil, recording == nil, !isImporting, let source else { return false }

        return source.mono16k.count >= TranscriptionPlan.minimumSamples && modelSize != nil
    }

    /// The phase as the screen and the Live Activity word it.
    var runStatusText: String {
        guard let run else { return "" }

        if run.cancelLatched {
            return String(localized: "Cancelling…", comment: "Transcribe screen: the run is stopping at the next chunk")
        }

        if run.paused {
            return String(localized: "Paused — cooling down", comment: "Transcribe screen and Live Activity: the device is too hot to carry on")
        }

        switch run.phase {
        case .separating:
            return String(localized: "Separating stems", comment: "Transcribe screen and Live Activity: Demucs is splitting the take")
        case .transcribing(stem: nil):
            return String(localized: "Transcribing", comment: "Transcribe screen and Live Activity: the model is running")
        case let .transcribing(stem: stem?):
            let name = StemNames.displayNames[stem]
            return String(localized: "Transcribing \(name)", comment: "Transcribe screen and Live Activity: the model is running over one stem, e.g. \"Transcribing Drums\"")
        }
    }

    // MARK: - Launch

    /// The Transcribe button: the Mac's `launchTranscriptionNow`, step for step where a phone
    /// has the same step.
    func launchTranscription() {
        guard canTranscribe, let source, let size = modelSize, let modelPath = models.path(for: size) else { return }

        let stemsPath = separateStems ? models.path(for: .stems) : nil
        let passes = TranscriptionPlan.passes(selected: selectedGroups, stems: stemsPath != nil)
        let runName = stemsPath != nil
            ? String(localized: "Stems", comment: "A version's name: \"Before Stems — 14:02\", saved before a stems run")
            : String(localized: "Transcribe", comment: "A version's name: \"Before Transcribe — 14:02\", saved before a run")

        // The transcription this run replaces is kept aside: a version of it when the run lands,
        // put back as it was when the run is cancelled or fails.
        transcriptionBeforeRun = projectSnapshot()
        staging.reset()
        // Every instrument the run finds is a new one, at unity and unmuted.
        mixer.resetStoredSettings()
        streamRawNotes([])
        lastRunSeconds = nil

        run = RunState(phase: stemsPath != nil ? .separating : .transcribing(stem: nil),
                       startedAt: Date(), runName: runName)

        let control = RunControl(engine: transcriber, separator: separator, gate: ThermalGate())
        runControl = control

        runSupport = RunSupport(fileName: droppedFileName ?? Self.recordingName, status: runStatusText) { [weak self] in
            self?.backgroundTimeExpired()
        }

        startDrain()

        print("NeuralSheet run: \(size.rawValue) model, \(passes.count) pass(es), groups \(selectedGroups.map(\.rawValue)), "
              + String(format: "%.2f s of audio", source.duration))

        runTask = Task { [weak self, transcriber, separator, staging] in
            let outcome = await Self.perform(source: source, passes: passes, modelPath: modelPath, stemsPath: stemsPath,
                                             engine: transcriber, separator: separator, staging: staging, control: control,
                                             onPhase: { phase in
                                                 Task { @MainActor in self?.setPhase(phase) }
                                             })

            self?.land(outcome, modelPath: modelPath)
        }
    }

    /// The Cancel button. Latched, because the engine only sees it at the next chunk; an
    /// abandoned separation ends at once. Pressing it again is harmless.
    func cancelTranscription() {
        guard var run, !run.cancelLatched else { return }

        run.cancelLatched = true
        self.run = run
        runSupport?.update(progress: run.progress, status: runStatusText)
        runControl?.cancel()
    }

    /// The scene is active again: the models folder may have changed, and a run the system ended
    /// in the background starts again from the start (chunks are not checkpointed in v1).
    func sceneBecameActive() {
        models.rescan()

        if resumeRunWhenActive, run == nil {
            resumeRunWhenActive = false
            launchTranscription()
        }
    }

    /// The document is closing: nothing may outlive it.
    func closeDocument() {
        resumeRunWhenActive = false
        cancelTranscription()
        cancelRecording()
        engine.stop()
    }

    private func backgroundTimeExpired() {
        guard run != nil else { return }

        print("NeuralSheet run: the system ended the background time; cancelling, to resume on return")
        resumeRunWhenActive = true
        cancelTranscription()
    }

    private static var recordingName: String {
        String(localized: "Recording", comment: "The Live Activity's name for a take that was recorded rather than imported")
    }

    // MARK: - The run, off the main actor

    /// The separator if there is one, then each pass through the engine, awaited in turn. The
    /// engine and the separator call back on their own threads; nothing here touches the model.
    nonisolated private static func perform(source: SourceAudio, passes: [TranscriptionPass], modelPath: URL,
                                            stemsPath: URL?, engine: TranscriptionEngine, separator: StemSeparator,
                                            staging: TranscriptionStaging, control: RunControl,
                                            onPhase: @escaping @Sendable (RunState.Phase) -> Void) async -> RunOutcome {
        var inputs: [[Float]] = [source.mono16k]

        if let stemsPath {
            switch await separate(source, modelPath: stemsPath, separator: separator, staging: staging, control: control) {
            case let .success(stems):
                inputs = stems.all
            case .failure(.cancelled):
                return .cancelled
            case let .failure(.failed(message)):
                return .failed(reason: String(localized: "the stems could not be separated: \(message)",
                                              comment: "The reason in a failed transcription's alert, after \"could not be loaded or run:\""))
            }
        }

        var notes: [EngineNote] = []

        for (pass, samples) in zip(passes, inputs) {
            guard !control.isCancelled else { return .cancelled }

            // A stem too short for the model contributes nothing rather than failing the run.
            guard samples.count >= TranscriptionPlan.minimumSamples else { continue }

            onPhase(.transcribing(stem: pass.stem))

            let result: Result<[EngineNote], EngineError> = await withCheckedContinuation { continuation in
                engine.run(
                    modelPath: modelPath,
                    groups: pass.engineGroups,
                    samples16k: samples,
                    onUpdate: { update in
                        var scaled = update
                        scaled.progress = pass.overallProgress(update.progress)
                        staging.stage(scaled)
                        // Between chunks: held here, on the engine's thread, while the device is hot.
                        control.gate.waitWhileHot()
                        return !control.isCancelled
                    },
                    completion: { continuation.resume(returning: $0) })
            }

            switch result {
            case let .success(passNotes):
                notes.append(contentsOf: passNotes)
            case .failure(.cancelled):
                return .cancelled
            case let .failure(error):
                return .failed(reason: TranscriptionRun.failureReason(error, modelPath: modelPath))
            }
        }

        return .success(notes)
    }

    private enum SeparationFailure: Error {
        case cancelled
        case failed(String)
    }

    /// The separator, awaited. The library cannot be stopped, so a cancel abandons the run: its
    /// completion is dropped and the wait ends at once.
    nonisolated private static func separate(_ source: SourceAudio, modelPath: URL, separator: StemSeparator,
                                             staging: TranscriptionStaging,
                                             control: RunControl) async -> Result<StemSeparator.Stems, SeparationFailure> {
        let wait = SeparationWait()
        control.separation = wait

        let result = await withCheckedContinuation { continuation in
            wait.install(continuation)

            separator.run(
                modelPath: modelPath,
                source: source,
                onProgress: { progress in
                    // The separation is the first half of the bar.
                    staging.stage(EngineUpdate(newNotes: [], finalizedThrough: 0,
                                               progress: TranscriptionPlan.separationProgress(progress)))
                },
                completion: { result in
                    switch result {
                    case let .success(stems): wait.resume(.success(stems))
                    case let .failure(failure): wait.resume(.failure(SeparationMessage(text: failure.message)))
                    }
                })

            if control.isCancelled {
                wait.resume(.success(nil))
            }
        }

        control.separation = nil

        switch result {
        case let .success(stems?): return .success(stems)
        case .success(nil): return .failure(.cancelled)
        case let .failure(message): return .failure(.failed(message.text))
        }
    }

    // MARK: - On the main actor

    private func startDrain() {
        Task { [weak self] in
            while let self, self.run != nil {
                self.drain()
                try? await Task.sleep(for: Self.drainInterval)
            }
        }
    }

    /// 30 Hz while a run is in flight; the post-processing runs only when the drain brings
    /// something, at the model's pace.
    private func drain() {
        guard var run else { return }

        let drained = staging.drain()
        let advances = drained.advances(past: run.finalizedThrough)

        run.progress = max(run.progress, drained.progress)
        run.finalizedThrough = max(run.finalizedThrough, drained.finalizedThrough)

        // The gate holds the engine's thread; the drain is where the screen hears of it.
        let paused = runControl?.gate.isPaused ?? false

        if paused != run.paused {
            print("NeuralSheet run: \(paused ? "paused, the device is hot" : "resumed")")
            run.paused = paused
        }

        if run != self.run {
            self.run = run
        }

        if advances {
            streamRawNotes(rawNotes + drained.rawNotes)
        }

        runSupport?.update(progress: run.progress, status: runStatusText)
    }

    private func setPhase(_ phase: RunState.Phase) {
        guard var run, run.phase != phase else { return }

        run.phase = phase
        self.run = run
        runSupport?.update(progress: run.progress, status: runStatusText)
    }

    /// The Mac's `handleFinished`: the run's own result lands as the document, after the notes it
    /// replaces are saved as a version; a cancel or a failure puts back what was there.
    private func land(_ outcome: RunOutcome, modelPath: URL) {
        guard let finished = run else { return }

        drain()

        let before = transcriptionBeforeRun ?? projectSnapshot()
        let progress = run?.progress ?? 0

        run = nil
        runTask = nil
        runControl = nil
        transcriptionBeforeRun = nil
        staging.reset()

        switch outcome {
        case let .success(final):
            saveVersionBeforeRun(finished.runName, notes: before.document?.events)
            installDocument(rawNotes: TranscriptionRun.landing(final, settings: settings))
            registerUndo(finished.runName, before: before)
            lastRunSeconds = Date().timeIntervalSince(finished.startedAt)
            runSupport?.finish(status: String(localized: "Done", comment: "Live Activity: the run has finished"), progress: 1)

            print("NeuralSheet run: \(document?.notes.count ?? 0) notes from \(final.count) raw in "
                  + String(format: "%.2f s", lastRunSeconds ?? 0)
                  + " with \(modelPath.lastPathComponent) on \(transcriber.lastBackendName ?? "?")")

        case .cancelled:
            restore(before)
            runSupport?.finish(status: String(localized: "Cancelled", comment: "Live Activity: the run was cancelled"),
                               progress: progress)
            print("NeuralSheet run: cancelled")

        case let .failed(reason):
            restore(before)
            runSupport?.finish(status: TranscriptionRun.failedTitle, progress: progress)
            alert = MobileAlert(title: TranscriptionRun.failedTitle, message: TranscriptionRun.failedBody(reason))
            print("NeuralSheet run: failed: \(reason)")
        }

        runSupport = nil
    }

    /// The notes a run replaces, kept as a version first (versions design §2), named as the Mac
    /// names it: "Before Transcribe — 14:02".
    private func saveVersionBeforeRun(_ run: String, notes: [NoteEvent]?) {
        guard let notes, !notes.isEmpty else { return }

        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        versions.append(NoteVersion(name: String(localized: "Before \(run) — \(time)", comment: "A version saved before a run, e.g. \"Before Transcribe — 14:02\""),
                                    notes: notes))
    }
}
