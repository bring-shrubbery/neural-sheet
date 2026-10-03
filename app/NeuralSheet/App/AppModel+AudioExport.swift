import AppKit
import Foundation
import NeuralSheetCore

/// File → Export Audio… (audio export design §2): the save panel and its accessory, then the
/// offline render on a detached task with the progress sheet and its Cancel. The live engine is
/// only read from -- the mix, master and split as heard, the sound bank in force -- never driven,
/// so playback carries on while the file renders.
extension AppModel {
    /// The render in flight.
    struct AudioRenderJob {
        /// Ties a completion to the render that launched it.
        let id = UUID()
        /// The file being written, for the sheet.
        let fileName: String
        /// 0…1 by frames.
        var progress: Double = 0
        var task: Task<Void, Never>?
    }

    /// A take to render, and nothing rendering already.
    var canExportAudio: Bool {
        source != nil && (state == .audioLoaded || state == .populated) && audioRender == nil && importJob == nil
    }

    /// The two choices with the synth in them need a finished transcription.
    var canExportAudioMidi: Bool { canExport }

    // MARK: - The command

    /// File → Export Audio… (⌥⌘E): the panel with What / Range / Format, defaults remembered, then
    /// the render into a scratch file moved over the chosen one only once it is whole.
    func exportAudio() {
        guard canExportAudio, let source else { return }

        let remembered = ExportAudioPanel.Choice(what: settings.audioExportWhat, markedRange: settings.audioExportMarkedRange,
                                                 format: settings.audioExportFormat)
        let marked = editor.range

        guard let (choice, url) = ExportAudioPanel.run(takeName: exportTakeName, directory: paths.musicFolder,
                                                       initial: remembered, hasRange: marked != nil,
                                                       hasNotes: canExportAudioMidi),
              canExportAudio
        else { return }

        settings.audioExportWhat = choice.what
        settings.audioExportMarkedRange = choice.markedRange
        settings.audioExportFormat = choice.format

        let whole = 0 ... max(source.duration, 0)
        let range = choice.markedRange ? marked.map { $0.lowerBound ... $0.upperBound } ?? whole : whole

        // As heard is what the engine is told now: the hold or the split's middle included.
        let job = OfflineRenderer.Job(spec: RenderSpec(what: choice.what, range: range, format: choice.format),
                                      take: source, notes: notes, mixer: mixer,
                                      soundBankURL: engine.synthBank.soundBankURL, mix: engine.mix,
                                      masterGainDb: engine.masterGainDb, stereoSplit: engine.stereoSplit)

        startAudioRender(job, to: url)
    }

    /// The progress sheet's Cancel: the render stops at its next block and removes its file; the
    /// one the panel was replacing is untouched.
    func cancelAudioExport() {
        guard let render = audioRender else { return }

        audioRender = nil
        render.task?.cancel()
    }

    // MARK: - Render

    private func startAudioRender(_ job: OfflineRenderer.Job, to destination: URL) {
        var render = AudioRenderJob(fileName: destination.lastPathComponent)
        let renderID = render.id

        render.task = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = AppModel.renderAudio(job, to: destination) { [weak self] fraction in
                guard let model = self else { return }

                Task { @MainActor in
                    model.setAudioRenderProgress(fraction, renderID: renderID)
                }
            }

            await self?.finishAudioRender(failure, renderID: renderID)
        }

        audioRender = render
    }

    /// Off the main actor: renders into a scratch folder on the destination's volume and moves the
    /// file over the destination once whole. Nil on success or cancel.
    nonisolated private static func renderAudio(_ job: OfflineRenderer.Job, to destination: URL,
                                                progress: @escaping @Sendable (Double) -> Void) -> Error? {
        let manager = FileManager.default

        do {
            let scratchFolder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: scratchFolder) }

            let scratch = scratchFolder.appendingPathComponent(destination.lastPathComponent)

            // A hop per percent, not per block.
            var reported = -1
            let finished = try OfflineRenderer.render(job, to: scratch, progress: { fraction in
                let percent = Int(fraction * 100)
                if percent != reported {
                    reported = percent
                    progress(fraction)
                }
            })

            guard finished, !Task.isCancelled else { return nil }

            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try manager.moveItem(at: scratch, to: destination)
            }

            return nil
        } catch {
            return Task.isCancelled ? nil : error
        }
    }

    private func setAudioRenderProgress(_ progress: Double, renderID: UUID) {
        guard var render = audioRender, render.id == renderID else { return }

        render.progress = progress
        audioRender = render
    }

    private func finishAudioRender(_ failure: Error?, renderID: UUID) {
        // Cancelled: the sheet is already down and there is nothing to say.
        guard audioRender?.id == renderID else { return }

        audioRender = nil

        if let failure {
            showError(AppModel.audioWriteFailureTitle, failure.localizedDescription)
        }
    }
}
