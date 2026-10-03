import AppKit
import Foundation
import NeuralSheetCore

/// The transcription models: which size a run would use, the downloads, and the 10 Hz rescan
/// that notices a checkpoint arriving or going away.
extension AppModel {
    /// The size a run would use: the preference when installed, else Medium, else the first
    /// installed size, else nil (nothing to transcribe with). The same rule as `ModelStore.resolve`,
    /// read off ``installedModels`` so it is observable.
    var modelSize: ModelSize? {
        if installedModels.contains(settings.modelSize) {
            return settings.modelSize
        }

        if installedModels.contains(ModelManifest.defaultSize) {
            return ModelManifest.defaultSize
        }

        return ModelSize.transcription.first(where: installedModels.contains)
    }

    /// No model installed and nothing else to do on the roll: the roll says so, and points at
    /// Settings (§3.2).
    var needsModelNotice: Bool {
        !hasTranscriptionModel && (state == .empty || state == .audioLoaded)
    }

    /// The preference; ``modelSize`` is what a run resolves it to.
    func setModelSize(_ size: ModelSize) {
        settings.modelSize = size
    }

    func startDownload(_ size: ModelSize) {
        downloader.start(size)
        refreshDownloadPhase(size)
    }

    func cancelDownload(_ size: ModelSize) {
        downloader.cancel(size)
    }

    /// Opens the models folder in the Finder, creating it first.
    func openModelsFolder() {
        try? paths.ensureDirectories()
        NSWorkspace.shared.open(paths.models)
    }

    // Internal: the init's download callback calls it.
    func refreshDownloadPhase(_ size: ModelSize) {
        let phase = downloader.phase(of: size)

        if downloadPhases[size] != phase {
            downloadPhases[size] = phase
        }

        // Idle after downloading means installed (or given up); either way the set may have moved.
        rescanInstalledModels()
    }

    /// 10 Hz, panel open or not (§3.2): the panel has to come back on its own when the last
    /// checkpoint disappears, and the toolbar's Transcribe button has to go with it.
    // Internal: the init starts it.
    func startModelPoll() {
        modelPollTimer?.invalidate()
        modelPollTimer = AppModel.repeatingTimer(hz: 10) { [weak self] in
            self?.rescanInstalledModels()
        }
    }

    private func rescanInstalledModels() {
        let installed = modelStore.installed()

        if installed != installedModels {
            installedModels = installed
        }
    }
}
