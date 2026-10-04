import Foundation
import NeuralSheetCore

/// Export Audio… (audio export design §2; sub-issue I): the Mac's What / Range / Format, asked by
/// the export sheet and remembered in the global settings, then the shared `OfflineRenderer` on a
/// detached task with the sheet's progress and Cancel, into a temporary folder the sheet shares
/// from. The live engine is only read from -- the mix, master and split as heard, the sound bank
/// in force -- so playback carries on while the file renders.
extension MobileModel {
    /// The render in flight.
    struct AudioRenderJob {
        /// Ties a completion to the render that launched it.
        let id = UUID()
        /// The file being written, for the sheet.
        let fileName: String
        let folder: URL
        /// 0…1 by frames.
        var progress: Double = 0
        var task: Task<Void, Never>?
    }

    /// A take to render, and nothing replacing it or rendering already.
    var canExportAudio: Bool {
        source != nil && run == nil && recording == nil && !isImporting && exports.audioRender == nil
    }

    /// The two choices with the synth in them need a finished transcription.
    var canExportAudioMidi: Bool { canExport }

    /// The last choice, as the Mac remembers it.
    var rememberedAudioChoice: ExportCommands.AudioChoice {
        ExportCommands.AudioChoice(what: settings.audioExportWhat, markedRange: settings.audioExportMarkedRange,
                                   format: settings.audioExportFormat)
    }

    // MARK: - The command

    /// The Export menu's Audio…: the sheet asks first.
    func requestAudioExport() {
        guard canExportAudio, !exports.isSheetShown else { return }

        exports.isAskingAudio = true
    }

    /// The sheet's Export: the choice remembered, then the render.
    func startAudioExport(_ choice: ExportCommands.AudioChoice) {
        exports.isAskingAudio = false

        guard canExportAudio, let source else { return }

        AppSettings.shared.settings.audioExportWhat = choice.what
        AppSettings.shared.settings.audioExportMarkedRange = choice.markedRange
        AppSettings.shared.settings.audioExportFormat = choice.format

        let folder: URL
        do {
            folder = try Self.newExportFolder()
        } catch {
            exports.failure = MobileAlert(title: Self.audioWriteFailureTitle, message: error.localizedDescription)
            return
        }

        // As heard is what the engine is told now: the hold or the split's middle included.
        let job = OfflineRenderer.Job(spec: ExportCommands.renderSpec(choice, marked: editor.range, duration: source.duration),
                                      take: source, notes: document?.events ?? [], mixer: mixer,
                                      soundBankURL: engine.synthBank.soundBankURL, mix: engine.mix,
                                      masterGainDb: engine.masterGainDb, stereoSplit: engine.stereoSplit)
        let destination = folder.appendingPathComponent(choice.format.fileName(takeName: exportTakeName))

        var render = AudioRenderJob(fileName: destination.lastPathComponent, folder: folder)
        let renderID = render.id

        render.task = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = ExportCommands.renderAudio(job, to: destination) { [weak self] fraction in
                guard let model = self else { return }

                Task { @MainActor in
                    model.setAudioRenderProgress(fraction, renderID: renderID)
                }
            }

            await self?.finishAudioRender(failure, destination: destination, renderID: renderID)
        }

        exports.audioRender = render
    }

    /// The sheet's Cancel, or the sheet closing: the render stops at its next block and its
    /// folder goes.
    func cancelAudioExport() {
        guard let render = exports.audioRender else { return }

        exports.audioRender = nil
        render.task?.cancel()
        Self.removeExportFolder(render.folder)
    }

    // MARK: - Render

    private func setAudioRenderProgress(_ progress: Double, renderID: UUID) {
        guard var render = exports.audioRender, render.id == renderID else { return }

        render.progress = progress
        exports.audioRender = render
    }

    private func finishAudioRender(_ failure: Error?, destination: URL, renderID: UUID) {
        // Cancelled: the sheet is already down and there is nothing to say.
        guard let render = exports.audioRender, render.id == renderID else { return }

        exports.audioRender = nil

        if let failure {
            Self.removeExportFolder(render.folder)
            exports.failure = MobileAlert(title: Self.audioWriteFailureTitle, message: failure.localizedDescription)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            exports.ready = ExportedFiles(folder: render.folder, files: [destination])
        } else {
            Self.removeExportFolder(render.folder)
        }
    }

    /// The message every failure of an audio export shows (issue #22, requirement 7).
    static var audioWriteFailureTitle: String {
        String(localized: "Could not write the audio file.", comment: "Alert title: File → Export Audio… or Export Stems… failed")
    }
}
