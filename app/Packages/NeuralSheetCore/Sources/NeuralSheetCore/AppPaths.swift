import Foundation

/// The size of a file, or 0 when it does not exist. No checkpoint is empty, so 0 reads as absent.
func fileByteSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Where the app keeps its own files.
///
/// Every path is injected, so tests never touch the real home directory.
///
/// On the Mac the models and `global.settings` live in the App Group container
/// ``appGroupIdentifier`` (Audio Unit design §2, "Models and settings"), so the plugin's
/// sandboxed extension reads the same checkpoints and settings the app downloaded and wrote. The
/// recordings stay under ``root``. iOS keeps everything in its own container (no group).
public struct AppPaths: Sendable {
    /// The App Group the Mac app and the Audio Unit extension share. Prefixed with the team
    /// rather than `group.`: macOS lets a team-prefixed group in on the code signature alone,
    /// while a `group.` one needs a provisioning profile that names it, which the Developer ID
    /// release (signed without a profile) does not carry; without it the app is kept out of the
    /// container. Both entitlements files name this string.
    public static let appGroupIdentifier = "6WCYZER5LX.com.quassum.neuralsheet"

    /// `~/Library/NeuralSheet` on the Mac, `Library/Application Support/NeuralSheet` in the iOS
    /// app's container.
    public var root: URL
    /// `<group>/Models` when there is a group container, `<root>/models` otherwise.
    public var models: URL
    public var recordings: URL
    /// `global.settings`: `<group>/global.settings` when there is a group container, beside the
    /// projects (`<root>`) otherwise.
    public var globalSettings: URL

    /// `~/Library/Group Containers/6WCYZER5LX.com.quassum.neuralsheet` on the Mac; nil on iOS, in
    /// a Mac build the system keeps out of the container, and in tests that do not ask for one,
    /// where the models and the settings stay under ``root``.
    public var groupContainer: URL?

    /// `~/Library/NeuralNote/models`: checkpoints an earlier NeuralNote installed, read-only.
    public var secondaryModels: URL

    /// Where a MIDI export lands by default.
    public var musicFolder: URL

    /// Where the models were before the group container (`<root>/models`), what
    /// ``migrateToGroupContainer()`` moves from.
    public var legacyModels: URL { root.appendingPathComponent("models", isDirectory: true) }

    /// Where `global.settings` was before the group container.
    public var legacyGlobalSettings: URL { root.appendingPathComponent("global.settings") }

    public init(root: URL, secondaryModels: URL, music: URL, groupContainer: URL? = nil) {
        self.root = root
        self.groupContainer = groupContainer
        if let groupContainer {
            models = groupContainer.appendingPathComponent("Models", isDirectory: true)
            globalSettings = groupContainer.appendingPathComponent("global.settings")
        } else {
            models = root.appendingPathComponent("models", isDirectory: true)
            globalSettings = root.appendingPathComponent("global.settings")
        }
        recordings = root.appendingPathComponent("recordings", isDirectory: true)
        self.secondaryModels = secondaryModels
        musicFolder = music
    }

    public static let standard: AppPaths = {
        let fileManager = FileManager.default
        #if os(macOS)
        let home = fileManager.homeDirectoryForCurrentUser
        #else
        // iOS has no user home outside the app's container; the fallbacks below land in it.
        let home = URL.homeDirectory
        #endif
        let library =
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library", isDirectory: true)
        #if os(macOS)
        let root = library.appendingPathComponent("NeuralSheet", isDirectory: true)
        let group = AppPaths.usableGroupContainer()
        #else
        // The app's own Application Support (iOS app design §2): the models, the settings and the
        // takes in progress belong to the app, not to the user's documents.
        let support =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? library.appendingPathComponent("Application Support", isDirectory: true)
        let root = support.appendingPathComponent("NeuralSheet", isDirectory: true)
        let group: URL? = nil
        #endif

        return AppPaths(
            root: root,
            secondaryModels: library.appendingPathComponent("NeuralNote/models", isDirectory: true),
            music: fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Music", isDirectory: true),
            groupContainer: group)
    }()

    /// Creates the directories the app writes to. The secondary models directory belongs to another
    /// app and the music folder to the user, so neither is created here.
    public func ensureDirectories() throws {
        for directory in [root, models, recordings] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// The two files the autosaved session used to be (`session.json`, `transcription.json`,
    /// beside the settings): a project file holds that now, so they go at launch. Quiet when there
    /// are none.
    public func deleteLegacySessionFiles() {
        for name in ["session.json", "transcription.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Empties the recordings folder. A take lives there only while its project is open -- a save
    /// copies it into the package and a close deletes it -- so anything there at launch is a
    /// crash's leftover. The folder itself stays.
    public func sweepRecordings() {
        let manager = FileManager.default

        guard let entries = try? manager.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) else {
            return
        }

        for entry in entries {
            try? manager.removeItem(at: entry)
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

    /// The size to transcribe with: the preference, else the default, else any transcription
    /// checkpoint installed. Never the stems.
    public func resolve(preferred: ModelSize?) -> ModelSize? {
        if let preferred, ModelSize.transcription.contains(preferred), installedPath(for: preferred) != nil {
            return preferred
        }

        if installedPath(for: ModelManifest.defaultSize) != nil {
            return ModelManifest.defaultSize
        }

        return ModelSize.transcription.first { installedPath(for: $0) != nil }
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
