import Foundation
import NeuralSheetCore
import Testing

/// The extension's view of the models: the group container's `Models/` folder through `AppPaths`
/// and `ModelStore`, checked against a fake group in a temporary directory.
private struct FakeGroup: ~Copyable {
    let directory: URL
    let paths: AppPaths

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginModelsTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(root: directory.appendingPathComponent("Library/NeuralSheet", isDirectory: true),
                         secondaryModels: directory.appendingPathComponent("NeuralNote/models", isDirectory: true),
                         music: directory.appendingPathComponent("Music", isDirectory: true),
                         groupContainer: directory.appendingPathComponent("Group", isDirectory: true))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var models: PluginModels { PluginModels(store: ModelStore(paths: paths)) }

    /// A sparse file of exactly the manifest's size, so it counts as installed and costs no disk.
    func install(_ size: ModelSize, in folder: URL? = nil) throws {
        let spec = ModelManifest.spec(for: size)
        let folder = folder ?? paths.models
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(spec.fileName)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(spec.byteSize))
        try handle.close()
    }
}

@Test func theModelsAndTheSettingsAreInTheGroup() {
    let group = FakeGroup()

    #expect(group.paths.models == group.directory.appendingPathComponent("Group/Models", isDirectory: true))
    #expect(group.paths.globalSettings == group.directory.appendingPathComponent("Group/global.settings"))
}

@Test func noModelIsTheEmptyState() {
    let group = FakeGroup()
    let models = group.models

    #expect(models.isEmpty)
    #expect(!models.stemsInstalled)
    #expect(models.folder == group.paths.models)
    #expect(models.size(picked: .small, preferred: .medium) == nil)
}

@Test func theStemsAloneAreStillTheEmptyState() throws {
    let group = FakeGroup()
    try group.install(.stems)

    #expect(group.models.isEmpty)
    #expect(group.models.stemsInstalled)
}

@Test func installedModelsAreListedInOrder() throws {
    let group = FakeGroup()
    try group.install(.medium)
    try group.install(.small)
    try group.install(.stems)

    #expect(!group.models.isEmpty)
    #expect(group.models.transcription == [.small, .medium])
    #expect(group.models.stemsInstalled)
}

/// A checkpoint left in the old `~/Library/NeuralSheet/models` is not the extension's: the sandbox
/// cannot read it, and only the app's migration moves it.
@Test func theOldFolderIsNotLookedIn() throws {
    let group = FakeGroup()
    try group.install(.small, in: group.paths.legacyModels)

    #expect(group.models.isEmpty)
}

@Test func theSizeFollowsThePickThenTheSettingThenTheDefault() throws {
    let group = FakeGroup()
    try group.install(.small)
    try group.install(.large)
    let models = group.models

    #expect(models.size(picked: .large, preferred: .small) == .large)
    // A pick that is not installed falls back to the app's setting.
    #expect(models.size(picked: .medium, preferred: .small) == .small)
    // Neither installed, nor the default (medium): the first installed.
    #expect(models.size(picked: nil, preferred: .medium) == .small)
    #expect(models.size(picked: nil, preferred: nil) == .small)
}
