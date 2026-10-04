import Foundation
import NeuralSheetCore
import Observation
import os

/// A transcription run over the captured take (Audio Unit design §2, "Transcription"): the engine
/// over the take, or the separator and then the engine once per stem, as the Mac's
/// `AppModel+Transcription` and the iOS app's `MobileModel+Transcription` run it -- the same passes
/// and instruments (`TranscriptionPlan`), the same staging and stream (`TranscriptionRun`), the same
/// landing filter from the shared settings. The run is the extension's own process's, on the
/// engine's thread; the main actor drains it at 30 Hz.
///
/// The plugin does not edit (design §1): a finished run lands as a ``NoteDocument`` that only the
/// roll reads, and there are no versions or undo.
@Observable final class PluginTranscription {
    enum Phase: Equatable {
        case separating
        /// The take itself (nil), or one stem.
        case transcribing(stem: Int?)
    }

    /// Where the run in flight is.
    struct Run: Equatable {
        var phase: Phase
        /// 0…1 over the whole run.
        var progress: Float = 0
        /// Seconds: every note ending before this has been reported.
        var finalizedThrough: Double = 0
        /// True from Cancel until the engine acknowledges it at the next chunk.
        var cancelLatched = false
        let startedAt: Date
    }

    /// What the last run did, for the status line and the log.
    struct Summary: Equatable {
        var notes: Int
        var seconds: Double
        var backend: String?
    }

    /// The run's outcome, as the main actor lands it.
    enum Outcome: Sendable {
        case success([EngineNote])
        case cancelled
        case failed(reason: String)
    }

    private(set) var run: Run? {
        didSet {
            if (oldValue == nil) != (run == nil) { notesChanged() }
        }
    }

    /// The notes streamed so far, merged as the app merges them while a run goes.
    private(set) var streamedNotes: [NoteEvent] = [] {
        didSet { notesChanged() }
    }

    /// The finished run's notes, filtered by the After transcription settings.
    private(set) var document: NoteDocument? {
        didSet { notesChanged() }
    }

    /// The last run's failure, in the app's words; nil after a success, a cancel or a clear.
    private(set) var failure: String?

    private(set) var summary: Summary?

    /// What the roll draws: the stream while a run goes, the document after.
    var notes: [NoteEvent] { run != nil ? streamedNotes : document?.events ?? [] }

    var isRunning: Bool { run != nil }

    /// Called with ``notes`` whenever they change, for the synth and the MIDI, which play them
    /// whether or not a view is watching.
    @ObservationIgnored var onNotesChanged: (([NoteEvent]) -> Void)?

    /// The run's start and end change which list ``notes`` is, so they report too.
    private func notesChanged() {
        onNotesChanged?(notes)
    }

    @ObservationIgnored private let engine = TranscriptionEngine()
    @ObservationIgnored private let separator = StemSeparator()
    @ObservationIgnored private let staging = TranscriptionStaging()
    @ObservationIgnored private var rawNotes: [NoteEvent] = []
    @ObservationIgnored private var control: PluginRunControl?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var landed: [CheckedContinuation<Void, Never>] = []

    /// The drain's period, the Mac's 30 Hz (§11.5).
    private static let drainInterval = Duration.milliseconds(33)

    // MARK: - Commands

    /// Starts a run over `source` with the checkpoint at `modelPath`, the Demucs weights at
    /// `stemsPath` for a stems run, the instruments picked (empty is Automatic), and the shared
    /// settings' post-run filter. Ignored while a run goes or for a take shorter than a second.
    func start(source: SourceAudio, modelPath: URL, stemsPath: URL?, groups: [InstrumentGroup],
               settings: GlobalSettings) {
        guard run == nil, source.mono16k.count >= TranscriptionPlan.minimumSamples else { return }

        let passes = TranscriptionPlan.passes(selected: groups, stems: stemsPath != nil)

        staging.reset()
        rawNotes = []
        streamedNotes = []
        document = nil
        failure = nil
        summary = nil
        run = Run(phase: stemsPath != nil ? .separating : .transcribing(stem: nil), startedAt: Date())

        let control = PluginRunControl(engine: engine, separator: separator)
        self.control = control

        startDrain()

        PluginLog.logger.info(
            "run: \(modelPath.lastPathComponent, privacy: .public), \(passes.count) pass(es), \(String(format: "%.2f", source.duration), privacy: .public) s")

        task = Task { [weak self, engine, separator, staging] in
            let outcome = await Self.perform(source: source, passes: passes, modelPath: modelPath, stemsPath: stemsPath,
                                             engine: engine, separator: separator, staging: staging, control: control,
                                             onPhase: { phase in
                                                 Task { @MainActor in self?.setPhase(phase) }
                                             })
            self?.land(outcome, settings: settings)
        }
    }

    /// Cancel: latched, because the engine sees it only at the next chunk; a separation is
    /// abandoned at once.
    func cancel() {
        guard var run, !run.cancelLatched else { return }

        run.cancelLatched = true
        self.run = run
        control?.cancel()
    }

    /// Forgets the notes (a new take, or Clear); cancels a run in flight.
    func clear() {
        cancel()
        streamedNotes = []
        rawNotes = []
        document = nil
        failure = nil
        summary = nil
    }

    /// The notes a host's saved state brought back (Audio Unit design §2, "State"): the document
    /// as it was saved, with no run and no summary. A run in flight is cancelled first.
    func restore(_ restored: NoteDocument?) {
        clear()
        document = restored
    }

    /// Returns once no run is in flight: at once when none is, else when the current one lands.
    func waitUntilIdle() async {
        guard run != nil else { return }

        await withCheckedContinuation { landed.append($0) }
    }

    // MARK: - The run, off the main actor

    /// The separator if asked for, then each pass through the engine in turn. Nothing here touches
    /// the model's state; the engine and the separator call back on their own threads.
    nonisolated private static func perform(source: SourceAudio, passes: [TranscriptionPass], modelPath: URL,
                                            stemsPath: URL?, engine: TranscriptionEngine, separator: StemSeparator,
                                            staging: TranscriptionStaging, control: PluginRunControl,
                                            onPhase: @escaping @Sendable (Phase) -> Void) async -> Outcome {
        var inputs: [[Float]] = [source.mono16k]

        if let stemsPath {
            switch await separate(source, modelPath: stemsPath, separator: separator, staging: staging, control: control) {
            case let .success(stems?):
                inputs = stems.all
            case .success(nil):
                return .cancelled
            case let .failure(message):
                return .failed(reason: "the stems could not be separated: \(message.text)")
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

    /// The separator, awaited; a cancel abandons it (the library cannot be stopped) and answers
    /// nil at once.
    nonisolated private static func separate(_ source: SourceAudio, modelPath: URL, separator: StemSeparator,
                                             staging: TranscriptionStaging,
                                             control: PluginRunControl) async -> PluginSeparationWait.Value {
        let wait = PluginSeparationWait()
        control.separation = wait

        let result = await withCheckedContinuation { continuation in
            wait.install(continuation)

            separator.run(
                modelPath: modelPath,
                source: source,
                onProgress: { progress in
                    staging.stage(EngineUpdate(newNotes: [], finalizedThrough: 0,
                                               progress: TranscriptionPlan.separationProgress(progress)))
                },
                completion: { result in
                    switch result {
                    case let .success(stems): wait.resume(.success(stems))
                    case let .failure(failure): wait.resume(.failure(PluginSeparationMessage(text: failure.message)))
                    }
                })

            if control.isCancelled {
                wait.resume(.success(nil))
            }
        }

        control.separation = nil
        return result
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

    /// The post-processing runs only when the drain brings something, at the model's pace.
    private func drain() {
        guard var run else { return }

        let drained = staging.drain()
        let advances = drained.advances(past: run.finalizedThrough)

        run.progress = max(run.progress, drained.progress)
        run.finalizedThrough = max(run.finalizedThrough, drained.finalizedThrough)

        if run != self.run {
            self.run = run
        }

        if advances {
            rawNotes += drained.rawNotes
            streamedNotes = TranscriptionRun.streamedNotes(rawNotes)
        }
    }

    private func setPhase(_ phase: Phase) {
        guard var run, run.phase != phase else { return }

        run.phase = phase
        self.run = run
    }

    /// The run's own result lands, authoritative over the stream; a cancel keeps nothing.
    private func land(_ outcome: Outcome, settings: GlobalSettings) {
        guard let finished = run else { return }

        drain()

        run = nil
        task = nil
        control = nil
        staging.reset()
        rawNotes = []

        switch outcome {
        case let .success(final):
            let notes = TranscriptionRun.landing(final, settings: settings)
            document = NoteDocument(events: notes)
            streamedNotes = []
            summary = Summary(notes: notes.count, seconds: Date().timeIntervalSince(finished.startedAt),
                              backend: engine.lastBackendName)
            PluginLog.logger.info(
                "run: \(notes.count) notes from \(final.count) raw in \(String(format: "%.2f", self.summary?.seconds ?? 0), privacy: .public) s on \(self.engine.lastBackendName ?? "?", privacy: .public)")

        case .cancelled:
            streamedNotes = []
            PluginLog.logger.info("run: cancelled")

        case let .failed(reason):
            streamedNotes = []
            failure = TranscriptionRun.failedBody(reason)
            PluginLog.logger.error("run: failed: \(reason, privacy: .public)")
        }

        let waiting = landed
        landed = []
        waiting.forEach { $0.resume() }
    }
}
