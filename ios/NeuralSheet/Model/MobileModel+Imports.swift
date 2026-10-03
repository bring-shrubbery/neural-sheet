import CoreTransferable
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// A take from outside the app (iOS app design §2, Imports): a file from Files, a video from
/// Photos, or audio or video handed over by the share sheet. Each is copied into a folder of its
/// own in the recordings -- a picked file is only lent to the app -- then, for a video, its audio
/// is extracted (`VideoAudioExtractor`), and the result is decoded (`AudioFileLoader`) off the
/// main actor and installed as the take under the file's name, as the Mac's `loadAudio` and
/// `importVideo` do. The take it replaces is one undo away.
extension MobileModel {
    /// The file importer's types: every extension the loader accepts, as the Mac's open panel
    /// lists them.
    static var importableContentTypes: [UTType] {
        AudioFileLoader.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Whether a take may come in now: not over a run, a recording or another import.
    var canImport: Bool { run == nil && recording == nil && !isImporting }

    /// A file from the file importer or the share sheet. `securityScoped` for a URL the system
    /// lends (Files, a document opened in place); the copy is made inside that access.
    func importFile(at url: URL, securityScoped: Bool) {
        guard canImport else { return }

        guard AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            alert = MobileAlert(title: String(localized: "Could not load the file.", comment: "Alert title: a dropped or opened file could not be read"),
                                message: Self.checkFormatMessage)
            return
        }

        let folder = newImportFolder()
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()

        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            removeImportFolder(folder)
            presentLoadFailure()
            return
        }

        decode(copy, in: folder)
    }

    /// A video from Photos, already copied into its import folder by ``PickedMovie``.
    func importPickedMovie(_ movie: PickedMovie) {
        guard canImport else {
            removeImportFolder(movie.url.deletingLastPathComponent())
            return
        }

        decode(movie.url, in: movie.url.deletingLastPathComponent())
    }

    /// Off the main actor: a video's audio extracted beside it (and the video's copy dropped),
    /// then the decode at the engine's rate; back on it, the take installed.
    private func decode(_ file: URL, in folder: URL) {
        isImporting = true

        let deviceRate = engine.sampleRate
        let displayName = file.deletingPathExtension().lastPathComponent

        Task { [weak self] in
            let result: Result<SourceAudio, any Error> = await Task.detached {
                do {
                    var audioFile = file

                    if AudioFileLoader.isVideo(file) {
                        audioFile = try await VideoAudioExtractor.extract(video: file, into: folder)
                        try? FileManager.default.removeItem(at: file)
                    }

                    return .success(try AudioFileLoader.load(url: audioFile, deviceRate: deviceRate, displayName: displayName))
                } catch {
                    return .failure(error)
                }
            }.value

            self?.finishImport(result, folder: folder)
        }
    }

    private func finishImport(_ result: Result<SourceAudio, any Error>, folder: URL) {
        isImporting = false

        switch result {
        case let .success(audio):
            let before = projectSnapshot()
            installSource(audio)
            registerUndo(String(localized: "Import", comment: "Undo menu: a take was imported"), before: before)
            print("NeuralSheet import: \(audio.droppedFileName ?? "?"), \(String(format: "%.2f", audio.duration)) s")

        case .failure:
            removeImportFolder(folder)
            presentLoadFailure()
        }
    }

    // MARK: - Folders and messages

    /// A folder of its own inside the recordings, so the file keeps its name (what the package's
    /// copy is named) without two imports of the same name ever sharing a path.
    func newImportFolder() -> URL {
        AppPaths.standard.recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Removes one import's folder, and only a folder directly inside the recordings.
    func removeImportFolder(_ folder: URL) {
        let parent = folder.deletingLastPathComponent().standardizedFileURL.path

        guard parent == AppPaths.standard.recordings.standardizedFileURL.path else { return }

        try? FileManager.default.removeItem(at: folder)
    }

    func presentLoadFailure() {
        alert = MobileAlert(title: String(localized: "Could not load the audio file.", comment: "Alert title: an audio file could not be decoded"),
                            message: Self.checkFormatMessage)
    }

    /// The accepted formats after a file that would not load.
    static var checkFormatMessage: String {
        let formats = AudioFileLoader.acceptedFormatsList

        return String(localized: "Check your file format (Accepted formats: \(formats)).",
                      comment: "Alert body: a file that would not load; the formats are extensions, e.g. \"mp3, wav, …\"")
    }
}

/// A video picked in Photos, received as a file: copied into an import folder of its own under
/// the name Photos gives it, before the picker's temporary copy goes.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = AppPaths.standard.recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: received.file, to: copy)

            return PickedMovie(url: copy)
        }
    }
}
