import AppKit
import Foundation
import NeuralSheetCore

/// File → Export Stems… (audio export design §2): the take's four stems as 24-bit WAV at its rate
/// and channel count, `<take name> - Drums.wav` …, into a folder the user picks. From the kept
/// separation when there is one; otherwise the take is separated first, with the status bar's
/// progress and its cancel, and the result kept for next time.
extension AppModel {
    /// Export Stems…'s own run: the separation when nothing is kept, then the writing.
    struct StemsExportJob {
        enum Phase: Equatable {
            case separating
            case writing
        }

        /// Ties a completion to the export that launched it, so an abandoned one landing late
        /// does nothing.
        let id = UUID()
        var phase: Phase = .separating
        /// 0…1 of the phase.
        var progress: Float = 0
        /// The folder the user chose.
        let destination: URL
        /// The writing, off the main actor.
        var task: Task<Void, Never>?
    }

    /// The message every failure of an audio export shows (issue #22, requirement 7).
    static var audioWriteFailureTitle: String {
        String(localized: "Could not write the audio file.", comment: "Alert title: File → Export Audio… or Export Stems… failed")
    }

    /// A take, nothing running over it, and stems to write: kept ones, or the model to make them.
    var canExportStems: Bool {
        source != nil && (state == .audioLoaded || state == .populated) && !jobActive && regionJob == nil
            && importJob == nil && stemsExport == nil && (stemsFolder != nil || hasStemsModel)
    }

    /// The take's name in the files: the dropped file's, or the project's for a recorded take.
    var exportTakeName: String {
        ExportCommands.takeName(droppedFileName: droppedFileName,
                                projectName: projectURL?.deletingPathExtension().lastPathComponent)
    }

    /// The status bar's caption while the export runs.
    var stemsExportCaption: String? {
        guard let stemsExport else { return nil }

        return stemsExport.phase == .separating
            ? String(localized: "SEPARATING", comment: "Status bar: the caption while the stems are separated")
            : String(localized: "EXPORTING", comment: "Status bar: the caption while Export Stems… writes the files")
    }

    // MARK: - The command

    /// File → Export Stems…: the folder first, so a separation the take needs is not waited on
    /// before the question, then the separation if nothing is kept, then the files.
    func exportStems() {
        guard canExportStems else { return }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Export Stems", comment: "File → Export Stems…'s folder panel")
        panel.message = String(localized: "Export Stems", comment: "File → Export Stems…'s folder panel")
        panel.prompt = String(localized: "Export", comment: "File → Export Stems…'s folder panel: the button")
        panel.directoryURL = paths.musicFolder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url, canExportStems else { return }

        if let kept = stemsFolder, AppModel.hasAllStems(in: kept) {
            writeStems(from: kept, to: folder)
        } else {
            runSeparationOnly(into: folder)
        }
    }

    /// The status bar's cross: the separation is abandoned (its thread removes what it kept), the
    /// writing stops and removes the files it wrote. Also every clear's, through ``clearNow()``.
    func cancelStemsExport() {
        guard let job = stemsExport else { return }

        stemsExport = nil

        switch job.phase {
        case .separating: separator.cancel()
        case .writing: job.task?.cancel()
        }
    }

    private static func hasAllStems(in folder: URL) -> Bool {
        (0..<StemNames.displayNames.count).allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(StemNames.cacheFileName(stem: $0)).path)
        }
    }

    // MARK: - Separation

    /// The separation alone, no transcription after it (audio export design §2), kept for the
    /// take, then on to the files.
    private func runSeparationOnly(into destination: URL) {
        guard let source, let stemsPath = modelStore.installedPath(for: .stems) else { return }

        // A cancelled separation's thread runs on until the library is done with it.
        guard !separator.isRunning else {
            showError(AppModel.audioWriteFailureTitle, String(localized: "A separation is still finishing. Try again in a moment.", comment: "Alert body: Export Stems… while a separation ends"))
            return
        }

        let job = StemsExportJob(destination: destination)
        let jobID = job.id
        stemsExport = job

        separator.run(
            modelPath: stemsPath,
            source: source,
            keepTo: newStemsFolder(),
            onProgress: { [weak self] progress in
                guard let self else { return }

                Task { @MainActor in
                    guard var job = self.stemsExport, job.id == jobID, job.phase == .separating else { return }

                    job.progress = max(job.progress, progress)
                    self.stemsExport = job
                }
            },
            completion: { [weak self] result in
                guard let self else { return }

                Task { @MainActor in
                    self.handleExportSeparated(result, jobID: jobID)
                }
            })
    }

    private func handleExportSeparated(_ result: Result<StemSeparator.Stems, StemSeparator.Failure>, jobID: UUID) {
        guard let job = stemsExport, job.id == jobID else {
            if case let .success(stems) = result, let folder = stems.keptFolder { removeImportFolder(folder) }
            return
        }

        stemsExport = nil

        switch result {
        case let .success(stems):
            guard let folder = stems.keptFolder else {
                showError(AppModel.audioWriteFailureTitle, String(localized: "The separated stems could not be written to disk.", comment: "Alert body: Export Stems… failed to write"))
                return
            }

            adoptStemsFolder(folder)
            writeStems(from: folder, to: job.destination)

        case let .failure(failure):
            showError(AppModel.audioWriteFailureTitle, String(localized: "The stems could not be separated: \(failure.message).",
                                                             comment: "Alert body: Export Stems… could not separate; the reason follows"))
        }
    }

    // MARK: - Writing

    /// Asks about each file already there -- Replace All covers the rest of the set -- then
    /// converts the kept `.caf` files off the main actor.
    private func writeStems(from kept: URL, to destination: URL) {
        guard let source else { return }

        var plan: [(source: URL, destination: URL)] = []
        var replaceAll = false

        for stem in StemNames.exportOrder {
            let target = destination.appendingPathComponent(StemNames.exportFileName(takeName: exportTakeName, stem: stem))

            if !replaceAll, FileManager.default.fileExists(atPath: target.path) {
                switch Dialogs.overwrite(fileName: target.lastPathComponent, folderName: destination.lastPathComponent) {
                case .replace: break
                case .replaceAll: replaceAll = true
                case .skip: continue
                case .cancel: return
                }
            }

            plan.append((kept.appendingPathComponent(StemNames.cacheFileName(stem: stem)), target))
        }

        guard !plan.isEmpty else { return }

        var job = StemsExportJob(destination: destination)
        job.phase = .writing
        let jobID = job.id
        let rate = source.deviceRate
        let channels = source.channelCount
        let frames = source.frameCount

        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = AppModel.convertStems(plan, sampleRate: rate, channels: channels, frameCount: frames) {
                [weak self] done in
                guard let model = self else { return }

                Task { @MainActor in
                    model.setStemsExportProgress(done, jobID: jobID)
                }
            }

            await self?.finishWritingStems(outcome, jobID: jobID)
        }

        stemsExport = job
    }

    /// Off the main actor: each stem through ``StemFiles/convert(_:to:sampleRate:channels:frameCount:)``
    /// into a scratch file on the destination's volume, moved over the target only once whole, so
    /// a failure or a cancel never leaves a half-written file or loses the one it was replacing.
    /// A cancel removes the files this export already wrote.
    nonisolated private static func convertStems(_ plan: [(source: URL, destination: URL)], sampleRate: Double,
                                                 channels: Int, frameCount: Int,
                                                 progress: @escaping @Sendable (Float) -> Void) -> Error? {
        let manager = FileManager.default
        var written: [URL] = []

        for (index, step) in plan.enumerated() {
            guard !Task.isCancelled else { break }

            do {
                let scratchFolder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: step.destination, create: true)
                defer { try? manager.removeItem(at: scratchFolder) }

                let scratch = scratchFolder.appendingPathComponent(step.destination.lastPathComponent)

                try StemFiles.convert(step.source, to: scratch, sampleRate: sampleRate, channels: channels,
                                      frameCount: frameCount)

                guard !Task.isCancelled else { break }

                if manager.fileExists(atPath: step.destination.path) {
                    _ = try manager.replaceItemAt(step.destination, withItemAt: scratch)
                } else {
                    try manager.moveItem(at: scratch, to: step.destination)
                }

                written.append(step.destination)
                progress(Float(index + 1) / Float(plan.count))
            } catch {
                return Task.isCancelled ? nil : error
            }
        }

        if Task.isCancelled {
            for url in written { try? manager.removeItem(at: url) }
        }

        return nil
    }

    private func setStemsExportProgress(_ progress: Float, jobID: UUID) {
        guard var job = stemsExport, job.id == jobID else { return }

        job.progress = progress
        stemsExport = job
    }

    private func finishWritingStems(_ failure: Error?, jobID: UUID) {
        // Cancelled, or the take cleared: nothing to say.
        guard stemsExport?.id == jobID else { return }

        stemsExport = nil

        if let failure {
            showError(AppModel.audioWriteFailureTitle, failure.localizedDescription)
        }
    }
}
