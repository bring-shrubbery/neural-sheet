import Foundation

/// A project on disk: a `Name.neuralsheet` folder the Finder shows as one file, holding
/// `project.json` (``ProjectState``), `transcription.json` (``ProjectTranscription``, absent
/// without a finished transcription) and `audio/<file>` (the audio, named in the state).
///
/// A write builds the whole package in a temporary directory beside the destination and swaps it
/// in with `replaceItemAt`, so a failure at any step leaves what was there untouched. The audio is
/// copied with `copyItem`, which on APFS is a clone: saving after an edit costs the JSON only.
public struct ProjectPackage: Sendable {
    public static let pathExtension = "neuralsheet"
    /// A recorded take's name inside the package; a dropped file keeps its own.
    public static let recordingFileName = "recording.wav"

    static let stateFileName = "project.json"
    static let transcriptionFileName = "transcription.json"
    static let audioDirectoryName = "audio"

    public var state: ProjectState
    public var transcription: ProjectTranscription?

    public init(state: ProjectState, transcription: ProjectTranscription?) {
        self.state = state
        self.transcription = transcription
    }

    /// Where the audio named `fileName` sits inside the package at `package`.
    public static func audioURL(in package: URL, fileName: String) -> URL {
        package.appendingPathComponent(audioDirectoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    // MARK: - Reading

    /// The package at `url`, and where its audio is (nil for a project without audio, checked to
    /// exist otherwise).
    ///
    /// `notAPackage` for anything that is not a `.neuralsheet` directory with a `project.json`;
    /// `unreadable` and `newerVersion` from the state; `missingAudio` when the state names a file
    /// that is not there. A transcription that cannot be read is dropped alone.
    public static func read(from url: URL) throws -> (package: ProjectPackage, audioURL: URL?) {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default

        guard url.pathExtension.lowercased() == pathExtension,
            manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            manager.fileExists(atPath: url.appendingPathComponent(stateFileName).path)
        else {
            throw ProjectError.notAPackage
        }

        let state = try ProjectState.read(from: url.appendingPathComponent(stateFileName))
        let transcription = ProjectTranscription.load(from: url.appendingPathComponent(transcriptionFileName))

        var resolvedAudioURL: URL?

        if !state.audioFileName.isEmpty {
            let audio = Self.audioURL(in: url, fileName: state.audioFileName)

            guard manager.fileExists(atPath: audio.path) else { throw ProjectError.missingAudio }

            resolvedAudioURL = audio
        }

        return (ProjectPackage(state: state, transcription: transcription), resolvedAudioURL)
    }

    // MARK: - Writing

    /// Writes the package to `url`, replacing whatever is there. `audioSource` is copied to
    /// `audio/<state.audioFileName>`, and may be inside the destination itself (the copy is made
    /// before the swap); nil writes no audio, and then `audioFileName` must be empty.
    public func write(to url: URL, audioSource: URL?) throws {
        precondition((audioSource == nil) == state.audioFileName.isEmpty,
                     "audioSource and audioFileName must agree")

        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        // Beside the destination: the same volume, so the swap is a rename and the copy a clone.
        let staging = parent.appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)", isDirectory: true)

        defer { try? manager.removeItem(at: staging) }

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)

            if let audioSource {
                let audioDirectory = staging.appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                try manager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                try manager.copyItem(at: audioSource, to: audioDirectory.appendingPathComponent(state.audioFileName))
            }

            try state.save(to: staging.appendingPathComponent(Self.stateFileName))

            if let transcription {
                try transcription.save(to: staging.appendingPathComponent(Self.transcriptionFileName))
            }

            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
        } catch let error as ProjectError {
            throw error
        } catch {
            throw ProjectError.couldNotWrite(error.localizedDescription)
        }
    }
}
