import Foundation
import NeuralSheetCore

/// A run over separated stems (stem separation design §5): the take through the separator,
/// then each stem through the transcription engine with the instruments it can hold, the four
/// results landing as one transcription. Shares the main run's state, staging, drain and
/// completion; only the launch and the hand-offs between the steps are here.
extension AppModel {
    struct StemsJob {
        enum Phase: Equatable {
            case separating
            case transcribing(stem: Int)
        }

        /// Ties a completion to the job that launched it, so an abandoned separation landing
        /// late can never apply to a newer run.
        let id = UUID()
        var phase: Phase = .separating
        var stems: StemSeparator.Stems?
        /// The finished stems' notes.
        var notes: [EngineNote] = []
        /// The transcription checkpoint every stem runs through.
        var modelPath: URL
    }

    /// Whether a transcription checkpoint is installed: what the Transcribe button and the
    /// no-model notice go by. The stems alone transcribe nothing.
    var hasTranscriptionModel: Bool {
        ModelSize.transcription.contains(where: installedModels.contains)
    }

    var hasStemsModel: Bool { installedModels.contains(.stems) }

    /// The Transcribe toolbar's toggle, remembered in the global settings.
    var separateStems: Bool {
        get { settings.separateStems }
        set { settings.separateStems = newValue }
    }

    /// The status bar's caption reads SEPARATING while this is true.
    var isSeparatingStems: Bool { stemsJob?.phase == .separating }

    // MARK: - The instruments per stem

    /// The groups each stem is decoded with (design §2): the drums as Drums, the bass as the two
    /// basses, the vocals as Voice, and the rest with the selection less those three, or every
    /// other named group when the selection is Automatic.
    nonisolated static func stemGroups(stem: Int, selected: [InstrumentGroup]) -> [InstrumentGroup] {
        let reserved: Set<InstrumentGroup> = [.drums, .acousticBass, .electricBass, .voice]

        switch stem {
        case 0: return [.drums]
        case 1: return [.acousticBass, .electricBass]
        case 3: return [.voice]
        default:
            let pool = selected.isEmpty ? InstrumentGroup.allCases : selected
            return pool.filter { !reserved.contains($0) }
        }
    }

    // MARK: - Launch

    /// Step 9 of the launch, the stems way: the separator first, the engine four times after.
    /// The state, the staging and the drain are already set up by the caller.
    func launchStemsRun(modelPath: URL, stemsPath: URL, source: SourceAudio) {
        let job = StemsJob(modelPath: modelPath)
        let jobID = job.id
        stemsJob = job

        separator.run(
            modelPath: stemsPath,
            source: source,
            // The stereo stems are kept for Export Stems… (audio export design §2).
            keepTo: newStemsFolder(),
            onProgress: { [weak self] progress in
                guard let self else { return }

                Task { @MainActor in
                    guard self.stemsJob?.id == jobID else { return }

                    // The separation is the first half of the bar.
                    self.transcription.progress = max(self.transcription.progress, progress * 0.5)
                }
            },
            completion: { [weak self] result in
                guard let self else { return }

                Task { @MainActor in
                    self.handleSeparated(result, jobID: jobID)
                }
            })
    }

    private func handleSeparated(_ result: Result<StemSeparator.Stems, StemSeparator.Failure>, jobID: UUID) {
        guard var job = stemsJob, job.id == jobID, jobActive else {
            // A run cleared meanwhile: its kept stems belong to nothing.
            if case let .success(stems) = result, let folder = stems.keptFolder { removeImportFolder(folder) }
            return
        }

        switch result {
        case let .success(stems):
            if let folder = stems.keptFolder { adoptStemsFolder(folder) }
            job.stems = stems
            stemsJob = job
            runStem(0)

        case let .failure(failure):
            stemsJob = nil
            // The main run's failure path, with the separation's own words: the separation
            // never reached the engine, so there is no `EngineError` to carry them.
            failRun(reason: "the stems could not be separated: \(failure.message)")
        }
    }

    /// One stem through the engine; its completion starts the next, or lands the whole run.
    private func runStem(_ index: Int) {
        guard var job = stemsJob, let stems = job.stems, index < stems.all.count else { return }

        job.phase = .transcribing(stem: index)
        stemsJob = job

        let jobID = job.id
        let groups = AppModel.stemGroups(stem: index, selected: selectedGroups).map(\.rawValue)
        let staging = self.staging
        let samples = stems.all[index]

        // A stem too short for the model contributes nothing rather than failing the run.
        guard samples.count >= 16_000 else {
            handleStemFinished(.success([]), stem: index, jobID: jobID)
            return
        }

        transcriber.run(
            modelPath: job.modelPath,
            groups: groups,
            samples16k: samples,
            onUpdate: { update in
                // The runs are the second half of the bar, a quarter each.
                var scaled = update
                scaled.progress = 0.5 + (Float(index) + update.progress) / 8
                staging.stage(scaled)
                return true
            },
            completion: { [weak self] result in
                guard let self else { return }

                Task { @MainActor in
                    self.handleStemFinished(result, stem: index, jobID: jobID)
                }
            })
    }

    private func handleStemFinished(_ result: Result<[EngineNote], EngineError>, stem: Int, jobID: UUID) {
        guard var job = stemsJob, job.id == jobID, jobActive else { return }

        switch result {
        case let .success(notes):
            job.notes.append(contentsOf: notes)
            stemsJob = job

            if stem + 1 < (job.stems?.all.count ?? 0) {
                runStem(stem + 1)
            } else {
                stemsJob = nil
                // Lands through the main run's completion, which applies the After transcription
                // settings (confidence design §2): the filter is per note, so once over the four
                // stems is what once per stem would give.
                handleFinished(.success(job.notes))
            }

        case .failure:
            stemsJob = nil
            handleFinished(result)
        }
    }

    // MARK: - The kept stems

    /// A fresh folder for a separation to keep its stems in, inside the recordings so the launch
    /// sweep finds it after a crash (audio export design §2).
    func newStemsFolder() -> URL {
        paths.recordings.appendingPathComponent("stems-\(UUID().uuidString)", isDirectory: true)
    }

    /// Makes `folder` the take's kept separation, removing the one it replaces.
    func adoptStemsFolder(_ folder: URL) {
        if let old = stemsFolder, old != folder { removeImportFolder(old) }

        stemsFolder = folder
    }

    // MARK: - Cancel and clear

    /// The status bar's cross during a stems run: an abandoned separation completes as a
    /// cancel at once, since its completion will never come; a stem's run is cancelled as the
    /// main run is.
    func cancelStemsRun() {
        guard let job = stemsJob else { return }

        switch job.phase {
        case .separating:
            separator.cancel()
            stemsJob = nil
            handleFinished(.failure(.cancelled))

        case .transcribing:
            transcriber.cancel()
        }
    }

    /// Every clear: whatever the separator is doing is abandoned and the job forgotten.
    func abandonStemsRun() {
        guard stemsJob != nil else { return }

        separator.cancel()
        stemsJob = nil
    }
}
