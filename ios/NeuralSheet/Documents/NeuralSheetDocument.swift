import Combine
import Foundation
import NeuralSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// A `.neuralsheet` package as a SwiftUI document (iOS app design §2, sub-issue C): what the
/// Files app, iCloud Drive and the system's document browser open and save.
///
/// `ProjectPackage` reads and writes URLs, and the document is handed file wrappers, so a read
/// unpacks the wrapper into a working copy in the temporary directory (``WorkingPackage``) and
/// reads that; the take is decoded from the copy and saved from it. A save writes the package
/// through `ProjectPackage.write` into a staging folder, takes the JSON files from there, and
/// hands back the audio file wrapper it was opened with when the take has not changed, so the
/// system's save keeps the file it already has rather than rewriting a long take's bytes.
///
/// iOS documents autosave, by platform convention; the Mac's projects do not (projects design
/// §4). Autosave follows the undo manager, which the editing work registers with (sub-issue F).
final class NeuralSheetDocument: ReferenceFileDocument {
    /// What a save captures on the main actor and writes off it.
    struct Snapshot: Sendable {
        var package: ProjectPackage
        var audio: Audio?
        /// Kept alive until the write is done: the audio may be read from it.
        var working: WorkingPackage?
    }

    /// The take a save puts in `audio/`.
    struct Audio: Sendable {
        var fileName: String
        var url: URL
        /// The take the package was opened with, whose file the package already holds.
        var unchanged: Bool
    }

    nonisolated static var readableContentTypes: [UTType] { [.neuralSheetProject] }

    /// The package as read, and where it was unpacked; nil for a new document.
    nonisolated let opened: OpenedPackage?

    /// The take's generation once installed: a later take is a new one and is saved from its
    /// own file.
    private var openedSourceGeneration: Int?

    /// Built on first use, on the main actor: the document is created off it.
    private(set) lazy var model: MobileModel = makeModel()

    /// A take handed over by the share sheet, which a new project starts with (sub-issue D).
    nonisolated let pendingTake: URL?

    /// A new, empty project.
    nonisolated init() {
        opened = nil
        pendingTake = nil
    }

    /// A new project whose take is `take`, a file the app owns (`IncomingTakes`), imported as
    /// soon as the project's model is built.
    nonisolated init(importing take: URL) {
        opened = nil
        pendingTake = take
    }

    nonisolated convenience init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    /// Unpacks `fileWrapper` into a working copy and reads it with the Mac's reader.
    nonisolated init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory else { throw ProjectError.notAPackage }

        let working = try WorkingPackage()

        do {
            try fileWrapper.write(to: working.packageURL, options: [], originalContentsURL: nil)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }

        let read = try ProjectPackage.read(from: working.packageURL)

        pendingTake = nil
        opened = OpenedPackage(package: read.package,
                               audioURL: read.audioURL,
                               transcriptionUnreadable: read.transcriptionUnreadable,
                               working: working)
    }

    private func makeModel() -> MobileModel {
        let model = MobileModel()

        guard let opened else {
            if let pendingTake {
                model.importFile(at: pendingTake, securityScoped: false)
                try? FileManager.default.removeItem(at: pendingTake.deletingLastPathComponent())
            }

            return model
        }

        var audio: SourceAudio?

        if let audioURL = opened.audioURL {
            do {
                audio = try model.loadAudio(url: audioURL, package: opened.package)
            } catch {
                model.loadProblem = String(localized: "The project's audio file could not be decoded.",
                                     comment: "Alert body: opening a project")
            }
        }

        let notesDropped = model.install(opened.package, audio: audio,
                                         transcriptionUnreadable: opened.transcriptionUnreadable)

        if notesDropped, model.loadProblem == nil {
            model.loadProblem = String(localized: "The notes in the file do not match its audio, or could not be read, and were left out. Saving the project will remove them from the file.",
                                 comment: "Alert body: a project's notes could not be read")
        }

        openedSourceGeneration = model.sourceGeneration
        print("NeuralSheet document: opened \(opened.package.state.audioFileName.isEmpty ? "a project without audio" : opened.package.state.audioFileName), "
              + "\(model.document?.notes.count ?? 0) notes, \(String(format: "%.2f", model.duration)) s, "
              + "\(String(format: "%.1f", model.exportTempo)) BPM, key \(model.editor.key?.name ?? "none")")

        return model
    }

    // MARK: - Saving

    nonisolated func snapshot(contentType: UTType) throws -> Snapshot {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { makeSnapshot() }
        }

        return DispatchQueue.main.sync { MainActor.assumeIsolated { makeSnapshot() } }
    }

    /// The model's package and the take to put in it; the package as opened while the model has
    /// not been built (nothing can have changed).
    func makeSnapshot() -> Snapshot {
        guard openedSourceGeneration != nil else {
            guard let opened else { return Snapshot(package: ProjectPackage(state: ProjectState(), transcription: nil)) }

            let audio = opened.audioURL.map {
                Audio(fileName: opened.package.state.audioFileName, url: $0, unchanged: true)
            }

            return Snapshot(package: opened.package, audio: audio, working: opened.working)
        }

        var audio: Audio?

        if let source = model.source {
            if model.sourceGeneration == openedSourceGeneration, let opened, let url = opened.audioURL {
                audio = Audio(fileName: opened.package.state.audioFileName, url: url, unchanged: true)
            } else if let path = source.sourcePath {
                // A take of its own: a recording under the Mac's name for one, a file under its own.
                let fileName = source.droppedFileName == nil ? ProjectPackage.recordingFileName : path.lastPathComponent
                audio = Audio(fileName: fileName, url: path, unchanged: false)
            }
        }

        return Snapshot(package: model.projectPackage(audioFileName: audio?.fileName ?? ""),
                        audio: audio,
                        working: opened?.working)
    }

    nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try fileWrapper(snapshot: snapshot, existingFile: configuration.existingFile)
    }

    /// The package as a directory wrapper. `ProjectPackage.write` builds it in a staging folder
    /// (the audio there is a clone, which costs nothing on APFS); the JSON files are taken from it
    /// and the audio is the existing file's own wrapper for an unchanged take, the take's file
    /// otherwise, read lazily.
    nonisolated func fileWrapper(snapshot: Snapshot, existingFile: FileWrapper?) throws -> FileWrapper {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("Saving-\(UUID().uuidString)", isDirectory: true)
        let packageURL = staging.appendingPathComponent("Project.\(ProjectPackage.pathExtension)", isDirectory: true)

        defer { try? manager.removeItem(at: staging) }

        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try snapshot.package.write(to: packageURL, audioSource: snapshot.audio?.url)

        var children: [String: FileWrapper] = [:]

        for name in try manager.contentsOfDirectory(atPath: packageURL.path) where name != WorkingPackage.audioDirectoryName {
            let file = FileWrapper(regularFileWithContents: try Data(contentsOf: packageURL.appendingPathComponent(name)))
            file.preferredFilename = name
            children[name] = file
        }

        if let audio = snapshot.audio {
            let file: FileWrapper

            if audio.unchanged,
                let existing = existingFile?.fileWrappers?[WorkingPackage.audioDirectoryName]?.fileWrappers?[audio.fileName],
                existing.isRegularFile
            {
                // Already named, and renaming a wrapper that has a parent would touch the parent.
                file = existing
            } else {
                file = try FileWrapper(url: audio.url, options: [])
                file.preferredFilename = audio.fileName
            }

            let directory = FileWrapper(directoryWithFileWrappers: [audio.fileName: file])
            directory.preferredFilename = WorkingPackage.audioDirectoryName
            children[WorkingPackage.audioDirectoryName] = directory
        }

        return FileWrapper(directoryWithFileWrappers: children)
    }
}

/// A package as read: its contents, where its audio is in the working copy, and whether its
/// transcription was there and unreadable.
struct OpenedPackage: Sendable {
    var package: ProjectPackage
    var audioURL: URL?
    var transcriptionUnreadable: Bool
    var working: WorkingPackage
}

/// A folder in the temporary directory holding an opened document's unpacked package, removed
/// when the last reference goes (the document, or a save still writing from it).
nonisolated final class WorkingPackage: Sendable {
    /// `ProjectPackage`'s own folder name for the audio.
    static let audioDirectoryName = "audio"

    let folder: URL
    let packageURL: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Document-\(UUID().uuidString)", isDirectory: true)
        packageURL = folder.appendingPathComponent("Project.\(ProjectPackage.pathExtension)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }
}
