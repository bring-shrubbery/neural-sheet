import Foundation
import NeuralSheetCore
import Observation
import UniformTypeIdentifiers

/// The sound bank the MIDI and the click play through on iPhone and iPad (sub-issue H). iOS has
/// no General MIDI bank and the app ships none, so Settings → Audio offers three things: download
/// GeneralUser GS (`SoundBankManifest`, through the models' downloader: resumed, SHA-256 checked),
/// copy a `.sf2` or `.dls` from Files, or none -- the MIDI synth's own fallback tone.
///
/// The folder holds at most one bank, the one in use: the default bank search
/// (`InstrumentSynthBank+DefaultBank`) picks up whatever is there, so a new bank replaces the
/// last. Each change bumps ``generation``; every open project's synths reload on their next poll.
@Observable
final class SoundBankLibrary {
    static let shared = SoundBankLibrary()

    /// The bank in the folder, or nil for the fallback tone.
    private(set) var current: URL?
    /// Where the GeneralUser GS download has got to.
    private(set) var phase: DownloadPhase = .idle
    /// Why the last import or load failed, for the Settings row; nil when all is well.
    var failure: String?
    /// Bumped whenever the folder's bank changes.
    private(set) var generation = 0

    @ObservationIgnored let folder: URL
    @ObservationIgnored private let downloader: ModelDownloader
    @ObservationIgnored private let store: ModelStore

    /// What Choose from Files… offers.
    static let contentTypes: [UTType] = ["sf2", "dls"].compactMap { UTType(filenameExtension: $0) }

    init(folder: URL = InstrumentSynthBank.soundBanksDirectory) {
        self.folder = folder

        let paths = SoundBankManifest.paths(soundBanks: folder)
        store = ModelStore(paths: paths, specs: [SoundBankManifest.spec])
        downloader = ModelDownloader(specs: [SoundBankManifest.spec], paths: paths, session: .shared,
                                     retryDelays: [2, 5, 10])

        prepareFolder()
        store.deleteStalePartFiles()
        current = Self.banks(in: folder).first

        downloader.onChange = { [weak self] _, _ in
            Task { @MainActor in self?.refreshPhase() }
        }
    }

    /// The bank's file name, for the row.
    var currentName: String? { current?.lastPathComponent }

    /// GeneralUser GS is the bank in use.
    var hasGeneralMidiBank: Bool { current?.lastPathComponent == SoundBankManifest.fileName }

    // MARK: - Download

    func startDownload() {
        failure = nil
        downloader.start(SoundBankManifest.downloaderKey)
        refreshPhase()
    }

    /// Stops the download, keeping the partial file so the next start resumes from it.
    func cancelDownload() {
        downloader.cancel(SoundBankManifest.downloaderKey)
    }

    private func refreshPhase() {
        let now = downloader.phase(of: SoundBankManifest.downloaderKey)

        if phase != now {
            phase = now
        }

        if now == .idle, let installed = store.installedPath(for: SoundBankManifest.downloaderKey), current != installed {
            keepOnly(installed)
        }
    }

    // MARK: - Files

    /// A `.sf2` or `.dls` from Files, copied into the folder in place of the bank there. A file
    /// that is not a sound bank is refused before any synth sees it, as on the Mac.
    func importBank(from url: URL, securityScoped: Bool) {
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard InstrumentSynthBank.isSoundBankFile(url) else {
            failure = Self.refusedMessage(url.lastPathComponent)
            return
        }

        let target = folder.appendingPathComponent(url.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }

            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            failure = error.localizedDescription
            return
        }

        failure = nil
        keepOnly(target)
    }

    /// None: the folder emptied, the MIDI synth's fallback tone. Synths already holding a bank
    /// keep it until the project is opened again (the synth has no way back to its own tone).
    func remove() {
        failure = nil
        keepOnly(nil)
    }

    /// A project's synths refused the bank (a damaged body the header check let through): it
    /// goes, and the row says so.
    func bankRefused(_ url: URL) {
        guard url == current else { return }

        failure = Self.refusedMessage(url.lastPathComponent)
        keepOnly(nil)
    }

    static func refusedMessage(_ fileName: String) -> String {
        String(localized: "\"\(fileName)\" could not be loaded as a SoundFont (.sf2) or DLS (.dls) file.",
               comment: "Settings → Audio → Sound bank (iOS): a chosen or downloaded file was refused")
    }

    // MARK: - The folder

    /// Every bank in the folder but `bank` goes; `bank` (or none) is the one in use.
    private func keepOnly(_ bank: URL?) {
        for other in Self.banks(in: folder) where other.standardizedFileURL != bank?.standardizedFileURL {
            try? FileManager.default.removeItem(at: other)
        }

        current = bank
        generation &+= 1
    }

    /// The `.sf2` and `.dls` files in the folder, by name, as the default bank search orders them.
    private static func banks(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        return entries
            .filter { ["sf2", "dls"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The folder exists and is left out of the device backup: a bank can be fetched again.
    private func prepareFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            print("NeuralSheet: could not prepare the sound banks folder: \(error.localizedDescription)")
        }
    }
}

extension MobileModel {
    /// The poll's check: the library's bank changed since these synths loaded theirs, so they load
    /// the folder's again -- the default bank search, which a new synth also makes.
    func reloadSoundBankIfChanged() {
        let library = SoundBankLibrary.shared

        guard library.generation != appliedSoundBankGeneration else { return }

        appliedSoundBankGeneration = library.generation

        guard library.current != nil else { return }

        if case .failure = engine.synthBank.setSoundBank(url: nil), let current = library.current {
            library.bankRefused(current)
        }
    }
}
