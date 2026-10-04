import Foundation
import Testing

@testable import NeuralSheetCore

private func makePathsTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePaths(in directory: URL) -> AppPaths {
    AppPaths(
        root: directory.appendingPathComponent("root", isDirectory: true),
        secondaryModels: directory.appendingPathComponent("secondary", isDirectory: true),
        music: directory.appendingPathComponent("music", isDirectory: true))
}

@Test func deleteLegacySessionFilesRemovesTheTwoAndNothingElse() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    try paths.ensureDirectories()

    let session = paths.root.appendingPathComponent("session.json")
    let transcription = paths.root.appendingPathComponent("transcription.json")
    try Data("{}".utf8).write(to: session)
    try Data("{}".utf8).write(to: transcription)
    try Data("x".utf8).write(to: paths.globalSettings)

    paths.deleteLegacySessionFiles()

    #expect(!FileManager.default.fileExists(atPath: session.path))
    #expect(!FileManager.default.fileExists(atPath: transcription.path))
    #expect(FileManager.default.fileExists(atPath: paths.globalSettings.path))
}

@Test func deleteLegacySessionFilesIsQuietWhenThereAreNone() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)

    paths.deleteLegacySessionFiles()
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}

@Test func sweepRecordingsEmptiesTheFolderAndKeepsIt() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    try paths.ensureDirectories()

    let take = paths.recordings.appendingPathComponent("recorded_audio2026-09-21_10-00-00.wav")
    let downsampled = paths.recordings.appendingPathComponent("recorded_audio2026-09-21_10-00-00_downsampled.wav")
    try Data("x".utf8).write(to: take)
    try Data("x".utf8).write(to: downsampled)

    paths.sweepRecordings()

    #expect(FileManager.default.fileExists(atPath: paths.recordings.path))
    let left = try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path)
    #expect(left.isEmpty)
}

// MARK: - The group container (Audio Unit design §2, "Models and settings")

private func makeGroupPaths(in directory: URL) -> AppPaths {
    AppPaths(
        root: directory.appendingPathComponent("root", isDirectory: true),
        secondaryModels: directory.appendingPathComponent("secondary", isDirectory: true),
        music: directory.appendingPathComponent("music", isDirectory: true),
        groupContainer: directory.appendingPathComponent("group", isDirectory: true))
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

@Test func aGroupContainerHoldsTheModelsAndTheSettingsButNotTheRecordings() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makeGroupPaths(in: directory)
    let group = directory.appendingPathComponent("group", isDirectory: true)

    #expect(paths.models == group.appendingPathComponent("Models", isDirectory: true))
    #expect(paths.globalSettings == group.appendingPathComponent("global.settings"))
    #expect(paths.recordings == paths.root.appendingPathComponent("recordings", isDirectory: true))
    #expect(paths.legacyModels == paths.root.appendingPathComponent("models", isDirectory: true))
    #expect(paths.legacyGlobalSettings == paths.root.appendingPathComponent("global.settings"))
}

@Test func migrationMovesTheModelsAndTheSettingsAndKeepsTheOldFolder() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makeGroupPaths(in: directory)
    try write("small", to: paths.legacyModels.appendingPathComponent("muscriptor-small-f16.gguf"))
    try write("part", to: paths.legacyModels.appendingPathComponent("muscriptor-medium-f16.gguf.abc.part"))
    try write("finder", to: paths.legacyModels.appendingPathComponent(".DS_Store"))
    try write("{\"a\":1}", to: paths.legacyGlobalSettings)
    try write("take", to: paths.recordings.appendingPathComponent("take.wav"))

    let outcome = paths.migrateToGroupContainer()

    #expect(outcome.movedModels == ["muscriptor-medium-f16.gguf.abc.part", "muscriptor-small-f16.gguf"])
    #expect(outcome.movedSettings)
    #expect(outcome.failed.isEmpty)
    #expect(read(paths.models.appendingPathComponent("muscriptor-small-f16.gguf")) == "small")
    #expect(read(paths.models.appendingPathComponent("muscriptor-medium-f16.gguf.abc.part")) == "part")
    #expect(read(paths.globalSettings) == "{\"a\":1}")
    // The old folder stays, with only the Finder's file; the recordings do not move.
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.legacyModels.path) == [".DS_Store"])
    #expect(!FileManager.default.fileExists(atPath: paths.legacyGlobalSettings.path))
    #expect(read(paths.recordings.appendingPathComponent("take.wav")) == "take")

    // Once is enough: a second launch finds nothing to do.
    #expect(paths.migrateToGroupContainer() == GroupContainerMigration())
}

@Test func migrationLeavesTheOldFilesWhenTheGroupAlreadyHasThem() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makeGroupPaths(in: directory)
    try write("old", to: paths.legacyModels.appendingPathComponent("muscriptor-small-f16.gguf"))
    try write("old settings", to: paths.legacyGlobalSettings)
    try write("new", to: paths.models.appendingPathComponent("muscriptor-medium-f16.gguf"))
    try write("new settings", to: paths.globalSettings)

    let outcome = paths.migrateToGroupContainer()

    #expect(!outcome.didMove)
    #expect(read(paths.legacyModels.appendingPathComponent("muscriptor-small-f16.gguf")) == "old")
    #expect(read(paths.legacyGlobalSettings) == "old settings")
    #expect(!FileManager.default.fileExists(atPath: paths.models.appendingPathComponent("muscriptor-small-f16.gguf").path))
    #expect(read(paths.globalSettings) == "new settings")
}

@Test func migrationMovesTheSettingsWithoutModels() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makeGroupPaths(in: directory)
    try write("settings", to: paths.legacyGlobalSettings)

    let outcome = paths.migrateToGroupContainer()

    #expect(outcome.movedModels.isEmpty)
    #expect(outcome.movedSettings)
    #expect(read(paths.globalSettings) == "settings")
}

@Test func migrationIsQuietWithoutAGroupOrAnythingToMove() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // No group container (iOS): models and settings already are the legacy paths.
    let plain = makePaths(in: directory)
    try write("small", to: plain.models.appendingPathComponent("muscriptor-small-f16.gguf"))
    #expect(plain.migrateToGroupContainer() == GroupContainerMigration())
    #expect(read(plain.models.appendingPathComponent("muscriptor-small-f16.gguf")) == "small")

    // A group and nothing in the old place: nothing is created.
    let fresh = makeGroupPaths(in: directory.appendingPathComponent("fresh", isDirectory: true))
    #expect(fresh.migrateToGroupContainer() == GroupContainerMigration())
    #expect(!FileManager.default.fileExists(atPath: fresh.models.path))
}

@Test func theModelStoreFindsAMovedCheckpoint() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makeGroupPaths(in: directory)
    let spec = ModelManifest.spec(for: .small)
    let legacy = paths.legacyModels.appendingPathComponent(spec.fileName)
    try FileManager.default.createDirectory(at: paths.legacyModels, withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: legacy.path, contents: nil))
    let handle = try FileHandle(forWritingTo: legacy)
    try handle.truncate(atOffset: UInt64(spec.byteSize))
    try handle.close()

    #expect(ModelStore(paths: paths).installed().isEmpty)
    paths.migrateToGroupContainer()
    #expect(ModelStore(paths: paths).installedPath(for: .small) == paths.models.appendingPathComponent(spec.fileName))
}

#if os(macOS)
@Test func standardPathsKeepTheModelsAndSettingsInTheGroupContainerWhenLetIn() {
    let paths = AppPaths.standard
    #expect(paths.recordings == paths.root.appendingPathComponent("recordings", isDirectory: true))

    // An unsigned test runner is kept out of the container, and then nothing moves.
    guard let group = paths.groupContainer else {
        #expect(paths.models == paths.legacyModels)
        #expect(paths.globalSettings == paths.legacyGlobalSettings)
        return
    }
    #expect(group.lastPathComponent == AppPaths.appGroupIdentifier)
    #expect(group.deletingLastPathComponent().lastPathComponent == "Group Containers")
    #expect(paths.models == group.appendingPathComponent("Models", isDirectory: true))
    #expect(paths.globalSettings == group.appendingPathComponent("global.settings"))
}
#endif
