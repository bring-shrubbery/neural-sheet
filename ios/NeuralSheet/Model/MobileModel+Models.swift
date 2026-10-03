import Foundation
import NeuralSheetCore
import Observation

/// The models on the device (iOS app design §2, sub-issue D): which are installed, the downloads
/// and their progress, one library for the whole app. The store and the downloader are the Mac's
/// (`ModelStore`, `ModelDownloader`: resume from the partial file, SHA-256 before install) over
/// the app's Application Support.
@Observable
final class ModelLibrary {
    static let shared = ModelLibrary()

    /// The models whose files are there at the manifest's size.
    private(set) var installed: Set<ModelSize> = []
    /// Where each download has got to; a size absent here is idle.
    private(set) var phases: [ModelSize: DownloadPhase] = [:]

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored let store: ModelStore
    @ObservationIgnored private let downloader: ModelDownloader
    @ObservationIgnored private let physicalMemory: UInt64

    /// The least memory the large model is offered on: it maps 2.7 GB and runs a larger network.
    static let largeModelMemory: UInt64 = 8 << 30

    init(paths: AppPaths = .standard, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.paths = paths
        self.physicalMemory = physicalMemory
        store = ModelStore(paths: paths)
        downloader = ModelDownloader(paths: paths)

        prepareFolder()
        store.deleteStalePartFiles()
        rescan()

        downloader.onChange = { [weak self] size, _ in
            Task { @MainActor in self?.refreshPhase(size) }
        }
    }

    // MARK: - What is offered

    /// The transcription sizes this device is offered: Large only with 8 GiB of memory or more.
    var offeredTranscriptionSizes: [ModelSize] {
        ModelSize.transcription.filter { $0 != .large || physicalMemory >= Self.largeModelMemory }
    }

    /// Every row the models settings show: the transcription sizes on offer, then Stems.
    var offeredSizes: [ModelSize] { offeredTranscriptionSizes + [.stems] }

    /// The installed transcription sizes, in order: what the picker chooses from.
    var installedTranscriptionSizes: [ModelSize] {
        ModelSize.transcription.filter(installed.contains)
    }

    var hasStemsModel: Bool { installed.contains(.stems) }

    /// The size a run uses: the preference when installed, else Medium, else the first installed
    /// size, else nil -- the Mac's `modelSize` rule.
    func resolvedSize(preferred: ModelSize) -> ModelSize? {
        if installed.contains(preferred), preferred != .stems {
            return preferred
        }

        if installed.contains(ModelManifest.defaultSize) {
            return ModelManifest.defaultSize
        }

        return installedTranscriptionSizes.first
    }

    func path(for size: ModelSize) -> URL? {
        store.installedPath(for: size)
    }

    func phase(of size: ModelSize) -> DownloadPhase {
        phases[size] ?? .idle
    }

    // MARK: - Downloads

    func startDownload(_ size: ModelSize) {
        downloader.start(size)
        refreshPhase(size)
    }

    /// Stops the download, keeping the partial file so the next start resumes from it.
    func cancelDownload(_ size: ModelSize) {
        downloader.cancel(size)
    }

    /// Removes an installed model's file, from the app's own folder only.
    func delete(_ size: ModelSize) {
        guard let url = store.installedPath(for: size),
            url.deletingLastPathComponent().standardizedFileURL == paths.models.standardizedFileURL
        else { return }

        try? FileManager.default.removeItem(at: url)
        rescan()
    }

    /// Looks again at the folder: on launch, after a download, and when the app comes back.
    func rescan() {
        let now = store.installed()

        if now != installed {
            installed = now
        }
    }

    private func refreshPhase(_ size: ModelSize) {
        let phase = downloader.phase(of: size)

        if phases[size] != phase {
            phases[size] = phase
        }

        rescan()
    }

    /// The folder exists and is left out of the device backup: the checkpoints are downloads the
    /// app can fetch again, hundreds of megabytes each.
    private func prepareFolder() {
        do {
            try paths.ensureDirectories()

            var models = paths.models
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try models.setResourceValues(values)
        } catch {
            print("NeuralSheet: could not prepare the models folder: \(error.localizedDescription)")
        }
    }
}

extension MobileModel {
    var models: ModelLibrary { .shared }
    var settings: GlobalSettings { AppSettings.shared.settings }

    /// The size the next run uses, or nil with no transcription model installed.
    var modelSize: ModelSize? {
        models.resolvedSize(preferred: settings.modelSize)
    }

    /// The picker's choice, remembered in the global settings.
    func setModelSize(_ size: ModelSize) {
        AppSettings.shared.settings.modelSize = size
    }

    /// The Stems toggle, remembered in the global settings; only takes effect with the Stems
    /// model installed.
    var separateStems: Bool {
        get { settings.separateStems }
        set { AppSettings.shared.settings.separateStems = newValue }
    }

    var hasTranscriptionModel: Bool { modelSize != nil }
}
