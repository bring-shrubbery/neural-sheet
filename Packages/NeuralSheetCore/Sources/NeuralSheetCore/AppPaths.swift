import Foundation

/// The size of a file, or 0 when it does not exist. No checkpoint is empty, so 0 reads as absent.
func fileByteSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Where the app keeps its own files.
///
/// Every path is injected, so tests never touch the real home directory.
public struct AppPaths: Sendable {
    /// `~/Library/NeuralSheet`
    public var root: URL
    public var models: URL
    public var recordings: URL
    public var globalSettings: URL
    public var session: URL

    /// `~/Library/NeuralNote/models`: checkpoints an earlier NeuralNote installed, read-only.
    public var secondaryModels: URL

    /// Where MIDI files are written for a drag out of the window.
    public var midiScratch: URL

    /// Where a MIDI export lands by default.
    public var musicFolder: URL

    public init(root: URL, secondaryModels: URL, temp: URL, music: URL) {
        self.root = root
        models = root.appendingPathComponent("models", isDirectory: true)
        recordings = root.appendingPathComponent("recordings", isDirectory: true)
        globalSettings = root.appendingPathComponent("global.settings")
        session = root.appendingPathComponent("session.json")
        self.secondaryModels = secondaryModels
        midiScratch = temp.appendingPathComponent("neuralsheet", isDirectory: true)
        musicFolder = music
    }

    public static let standard: AppPaths = {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let library =
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library", isDirectory: true)

        return AppPaths(
            root: library.appendingPathComponent("NeuralSheet", isDirectory: true),
            secondaryModels: library.appendingPathComponent("NeuralNote/models", isDirectory: true),
            temp: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            music: fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Music", isDirectory: true))
    }()

    /// Creates the directories the app writes to. The secondary models directory belongs to another
    /// app and the music folder to the user, so neither is created here.
    public func ensureDirectories() throws {
        for directory in [root, models, recordings, midiScratch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// The checkpoints on disk: which are usable, and which leftovers are not.
public struct ModelStore: Sendable {
    public let paths: AppPaths
    private let specs: [ModelSize: ModelSpec]

    public init(paths: AppPaths) {
        self.init(paths: paths, specs: ModelManifest.all)
    }

    /// - Parameter specs: The checkpoints to look for, one per size at most.
    public init(paths: AppPaths, specs: [ModelSpec]) {
        self.paths = paths
        self.specs = Dictionary(specs.map { ($0.size, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func spec(for size: ModelSize) -> ModelSpec {
        specs[size] ?? ModelManifest.spec(for: size)
    }

    /// Where the checkpoint is, or nil when it is not installed.
    ///
    /// "Installed" means the file exists with exactly the manifest byte size: there is no hash check
    /// at load time, and a wrong-size file is treated as absent and replaced by a download.
    public func installedPath(for size: ModelSize) -> URL? {
        let spec = spec(for: size)

        for directory in [paths.models, paths.secondaryModels] {
            let candidate = directory.appendingPathComponent(spec.fileName)

            if fileByteSize(candidate) == spec.byteSize {
                return candidate
            }
        }

        return nil
    }

    public func installed() -> Set<ModelSize> {
        Set(ModelSize.allCases.filter { installedPath(for: $0) != nil })
    }

    /// The size to transcribe with: the preference, else the default, else anything installed.
    public func resolve(preferred: ModelSize?) -> ModelSize? {
        if let preferred, installedPath(for: preferred) != nil {
            return preferred
        }

        if installedPath(for: ModelManifest.defaultSize) != nil {
            return ModelManifest.defaultSize
        }

        return ModelSize.allCases.first { installedPath(for: $0) != nil }
    }

    /// Removes partial files named for another digest: a build pinned to other weights started them
    /// and nothing will ever finish them.
    public func deleteStalePartFiles() {
        let fileManager = FileManager.default

        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: paths.models, includingPropertiesForKeys: nil)
        else { return }

        let live = Set(ModelSize.allCases.map { spec(for: $0).partFileName })
        let prefixes = ModelSize.allCases.map { spec(for: $0).fileName + "." }

        for entry in entries {
            let name = entry.lastPathComponent

            guard name.hasSuffix(".part"), !live.contains(name),
                prefixes.contains(where: name.hasPrefix)
            else { continue }

            try? fileManager.removeItem(at: entry)
        }
    }
}
