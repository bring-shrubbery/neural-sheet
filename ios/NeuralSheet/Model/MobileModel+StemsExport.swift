import Foundation
import NeuralSheetCore

/// Export Stems… (audio export design §2; sub-issue I): the take's four stems as 24-bit WAV at
/// its rate and channel count, `<take name> - Drums.wav` …, as the Mac writes them. From the kept
/// separation when there is one -- a stems run keeps its separation for the take, as the Mac's
/// does -- otherwise the take is separated first, with the sheet's progress and Cancel, and the
/// result kept for next time. The files go into a temporary folder the sheet shares from.
extension MobileModel {
    /// Export Stems…'s own run: the separation when nothing is kept, then the writing.
    struct StemsExportJob {
        enum Phase: Equatable {
            case separating
            case writing
        }

        /// Ties a completion to the export that launched it.
        let id = UUID()
        var phase: Phase = .separating
        /// 0…1 of the phase.
        var progress: Float = 0
        /// The folder the files are written into.
        let folder: URL
        /// The writing, off the main actor.
        var task: Task<Void, Never>?
    }

    /// A take, nothing running over it, and stems to write: kept ones, or the model to make them.
    var canExportStems: Bool {
        source != nil && run == nil && recording == nil && !isImporting && exports.stemsExport == nil
            && (exports.keptStems != nil || models.hasStemsModel)
    }

    // MARK: - The command

    /// The Export menu's Stems…: the kept separation's files, or the separation first.
    func exportStems() {
        guard canExportStems, !exports.isSheetShown else { return }

        let folder: URL
        do {
            folder = try Self.newExportFolder()
        } catch {
            exports.failure = MobileAlert(title: Self.audioWriteFailureTitle, message: error.localizedDescription)
            return
        }

        if let kept = exports.keptStems, ExportCommands.hasAllStems(in: kept) {
            writeStems(from: kept, to: folder)
        } else {
            runSeparationOnly(into: folder)
        }
    }

    /// The sheet's Cancel, or the sheet closing: the separation is abandoned (its thread removes
    /// what it kept), the writing stops; the folder goes either way.
    func cancelStemsExport() {
        guard let job = exports.stemsExport else { return }

        exports.stemsExport = nil

        switch job.phase {
        case .separating: separator.cancel()
        case .writing: job.task?.cancel()
        }

        Self.removeExportFolder(job.folder)
    }

    // MARK: - Kept stems

    /// A folder for a separation to keep its stems in, beside the takes.
    func newStemsFolder() -> URL {
        AppPaths.standard.recordings.appendingPathComponent("stems-\(UUID().uuidString)", isDirectory: true)
    }

    /// Makes `folder` the take's kept separation, removing the one it replaces.
    func adoptStemsFolder(_ folder: URL) {
        if let old = exports.keptStems, old != folder { removeImportFolder(old) }

        exports.keptStems = folder
    }

    /// The take changed or the document is closing: its separation goes.
    func dropKeptStems() {
        guard let kept = exports.keptStems else { return }

        exports.keptStems = nil
        removeImportFolder(kept)
    }

    // MARK: - Separation

    private func runSeparationOnly(into folder: URL) {
        guard let source, let stemsPath = models.path(for: .stems) else {
            Self.removeExportFolder(folder)
            return
        }

        // A cancelled separation's thread runs on until the library is done with it.
        guard !separator.isRunning else {
            Self.removeExportFolder(folder)
            exports.failure = MobileAlert(title: Self.audioWriteFailureTitle,
                                          message: String(localized: "A separation is still finishing. Try again in a moment.",
                                                          comment: "Alert body: Export Stems… while a separation ends"))
            return
        }

        let job = StemsExportJob(folder: folder)
        let jobID = job.id
        exports.stemsExport = job

        separator.run(
            modelPath: stemsPath,
            source: source,
            keepTo: newStemsFolder(),
            onProgress: { [weak self] progress in
                guard let model = self else { return }

                Task { @MainActor in
                    guard var job = model.exports.stemsExport, job.id == jobID, job.phase == .separating else { return }

                    job.progress = max(job.progress, progress)
                    model.exports.stemsExport = job
                }
            },
            completion: { [weak self] result in
                guard let model = self else { return }

                Task { @MainActor in
                    model.handleExportSeparated(result, jobID: jobID)
                }
            })
    }

    private func handleExportSeparated(_ result: Result<StemSeparator.Stems, StemSeparator.Failure>, jobID: UUID) {
        guard let job = exports.stemsExport, job.id == jobID else {
            if case let .success(stems) = result, let folder = stems.keptFolder { removeImportFolder(folder) }
            return
        }

        switch result {
        case let .success(stems):
            guard let kept = stems.keptFolder else {
                failStems(job, String(localized: "The separated stems could not be written to disk.", comment: "Alert body: Export Stems… failed to write"))
                return
            }

            adoptStemsFolder(kept)
            writeStems(from: kept, to: job.folder)

        case let .failure(failure):
            failStems(job, String(localized: "The stems could not be separated: \(failure.message).",
                                  comment: "Alert body: Export Stems… could not separate; the reason follows"))
        }
    }

    // MARK: - Writing

    /// The kept `.caf` files converted off the main actor, in the Mac's order and names.
    private func writeStems(from kept: URL, to folder: URL) {
        guard let source else { return }

        let plan = ExportCommands.stemPlan(kept: kept, destination: folder, takeName: exportTakeName)
        var job = StemsExportJob(folder: folder)
        job.phase = .writing
        let jobID = job.id
        let rate = source.deviceRate
        let channels = source.channelCount
        let frames = source.frameCount

        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = ExportCommands.convertStems(plan, sampleRate: rate, channels: channels, frameCount: frames) {
                [weak self] done in
                guard let model = self else { return }

                Task { @MainActor in
                    model.setStemsExportProgress(done, jobID: jobID)
                }
            }

            await self?.finishWritingStems(failure, files: plan.map(\.destination), jobID: jobID)
        }

        exports.stemsExport = job
    }

    private func setStemsExportProgress(_ progress: Float, jobID: UUID) {
        guard var job = exports.stemsExport, job.id == jobID else { return }

        job.progress = progress
        exports.stemsExport = job
    }

    private func finishWritingStems(_ failure: Error?, files: [URL], jobID: UUID) {
        // Cancelled, or the take cleared: nothing to say.
        guard let job = exports.stemsExport, job.id == jobID else { return }

        if let failure {
            failStems(job, failure.localizedDescription)
        } else {
            exports.stemsExport = nil
            exports.ready = ExportedFiles(folder: job.folder, files: files)
        }
    }

    private func failStems(_ job: StemsExportJob, _ message: String) {
        exports.stemsExport = nil
        Self.removeExportFolder(job.folder)
        exports.failure = MobileAlert(title: Self.audioWriteFailureTitle, message: message)
    }
}
