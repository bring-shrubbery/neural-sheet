import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

/// Runs `body` with an `AppPaths` rooted in a throwaway temp directory, never the real home.
private func withTempPaths(_ body: (AppPaths) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("neuralsheet-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let paths = AppPaths(
        root: base.appendingPathComponent("NeuralSheet", isDirectory: true),
        secondaryModels: base.appendingPathComponent("NeuralNote/models", isDirectory: true),
        music: base.appendingPathComponent("Music", isDirectory: true))

    try paths.ensureDirectories()
    try body(paths)
}

/// Creates a sparse file of exactly `size` bytes, so manifest-sized files cost no disk space.
private func makeFile(at url: URL, size: Int64) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
}

// MARK: - ModelSize

@Test func modelSizeDisplayNamesAndHints() {
    #expect(ModelSize.allCases == [.small, .medium, .large])
    #expect(ModelSize.small.displayName == "Small")
    #expect(ModelSize.medium.displayName == "Medium")
    #expect(ModelSize.large.displayName == "Large")
    #expect(ModelSize.small.hint == "Fastest")
    #expect(ModelSize.medium.hint == "Recommended")
    #expect(ModelSize.large.hint == "Largest, slowest")
}

// MARK: - ModelManifest

@Test func manifestFileNames() {
    #expect(ModelManifest.spec(for: .small).fileName == "muscriptor-small-f16.gguf")
    #expect(ModelManifest.spec(for: .medium).fileName == "muscriptor-medium-f16.gguf")
    #expect(ModelManifest.spec(for: .large).fileName == "muscriptor-large-f16.gguf")
}

@Test func manifestByteSizes() {
    #expect(ModelManifest.spec(for: .small).byteSize == 209_425_152)
    #expect(ModelManifest.spec(for: .medium).byteSize == 618_442_496)
    #expect(ModelManifest.spec(for: .large).byteSize == 2_739_142_176)
}

@Test func manifestDigests() {
    #expect(
        ModelManifest.spec(for: .small).sha256Hex
            == "925f55af65a20ebc4f8b45ceaf095a12b72493d436cb112623cd0041a1af23d4")
    #expect(
        ModelManifest.spec(for: .medium).sha256Hex
            == "3850cc9e5b436b17a09bd25b8f2615cb3366ab96a71e7b50f73a793a917fdf03")
    #expect(
        ModelManifest.spec(for: .large).sha256Hex
            == "35a750fb1ab1e77195cdc2c0b9b4aeea2f4d59f11f729f02af9920c4854ef72e")
}

@Test func manifestRevisionAndURL() {
    #expect(ModelManifest.revision == "d7045f94e8b19427f4ff9542975035e66596e51c")
    #expect(
        ModelManifest.spec(for: .medium).url.absoluteString
            == "https://huggingface.co/DamRsn/muscriptor-gguf/resolve/d7045f94e8b19427f4ff9542975035e66596e51c/v1/muscriptor-medium-f16.gguf"
    )
    #expect(
        ModelManifest.spec(for: .small).url.absoluteString
            == "https://huggingface.co/DamRsn/muscriptor-gguf/resolve/d7045f94e8b19427f4ff9542975035e66596e51c/v1/muscriptor-small-f16.gguf"
    )
}

@Test func manifestPartFileNames() {
    #expect(ModelManifest.spec(for: .medium).partFileName == "muscriptor-medium-f16.gguf.3850cc9e.part")
    #expect(ModelManifest.spec(for: .small).partFileName == "muscriptor-small-f16.gguf.925f55af.part")
}

@Test func manifestAllCoversEverySize() {
    #expect(ModelManifest.all.map(\.size) == ModelSize.allCases)
}

// MARK: - AppPaths

@Test func appPathsDerivesItsSubPaths() throws {
    try withTempPaths { paths in
        #expect(paths.models == paths.root.appendingPathComponent("models", isDirectory: true))
        #expect(paths.recordings == paths.root.appendingPathComponent("recordings", isDirectory: true))
        #expect(paths.globalSettings == paths.root.appendingPathComponent("global.settings"))
    }
}

@Test func ensureDirectoriesCreatesTheWritableFolders() throws {
    try withTempPaths { paths in
        var isDirectory: ObjCBool = false
        for url in [paths.root, paths.models, paths.recordings] {
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        // Calling it twice is not an error.
        try paths.ensureDirectories()
    }
}

@Test func standardPathsLiveUnderLibrary() {
    let paths = AppPaths.standard
    #expect(paths.root.lastPathComponent == "NeuralSheet")
    #expect(paths.root.deletingLastPathComponent().lastPathComponent == "Library")
    #expect(Array(paths.secondaryModels.pathComponents.suffix(2)) == ["NeuralNote", "models"])
    #expect(paths.musicFolder.lastPathComponent == "Music")
}

// MARK: - ModelStore

@Test func fileOfExactManifestSizeIsInstalled() throws {
    try withTempPaths { paths in
        let spec = ModelManifest.spec(for: .small)
        try makeFile(at: paths.models.appendingPathComponent(spec.fileName), size: spec.byteSize)

        let store = ModelStore(paths: paths)
        #expect(store.installedPath(for: .small) == paths.models.appendingPathComponent(spec.fileName))
        #expect(store.installed() == [.small])
    }
}

@Test func fileOfTheWrongSizeIsNotInstalled() throws {
    try withTempPaths { paths in
        let spec = ModelManifest.spec(for: .small)
        try makeFile(at: paths.models.appendingPathComponent(spec.fileName), size: spec.byteSize - 1)

        let store = ModelStore(paths: paths)
        #expect(store.installedPath(for: .small) == nil)
        #expect(store.installed().isEmpty)
    }
}

@Test func secondaryModelsDirectoryIsSearched() throws {
    try withTempPaths { paths in
        let spec = ModelManifest.spec(for: .medium)
        try makeFile(at: paths.secondaryModels.appendingPathComponent(spec.fileName), size: spec.byteSize)

        let store = ModelStore(paths: paths)
        #expect(
            store.installedPath(for: .medium) == paths.secondaryModels.appendingPathComponent(spec.fileName))
        #expect(store.installed() == [.medium])
    }
}

@Test func primaryModelsDirectoryWinsOverTheSecondary() throws {
    try withTempPaths { paths in
        let spec = ModelManifest.spec(for: .medium)
        try makeFile(at: paths.models.appendingPathComponent(spec.fileName), size: spec.byteSize)
        try makeFile(at: paths.secondaryModels.appendingPathComponent(spec.fileName), size: spec.byteSize)

        let store = ModelStore(paths: paths)
        #expect(store.installedPath(for: .medium) == paths.models.appendingPathComponent(spec.fileName))
    }
}

@Test func resolveFollowsPreferredThenMediumThenFirstInstalled() throws {
    try withTempPaths { paths in
        let store = ModelStore(paths: paths)
        #expect(store.resolve(preferred: .large) == nil)
        #expect(store.resolve(preferred: nil) == nil)

        let large = ModelManifest.spec(for: .large)
        try makeFile(at: paths.models.appendingPathComponent(large.fileName), size: large.byteSize)
        // Only large is installed: preferred small falls through medium to the first installed.
        #expect(store.resolve(preferred: .small) == .large)
        #expect(store.resolve(preferred: nil) == .large)
        #expect(store.resolve(preferred: .large) == .large)

        let medium = ModelManifest.spec(for: .medium)
        try makeFile(at: paths.models.appendingPathComponent(medium.fileName), size: medium.byteSize)
        // Medium wins over the first installed when the preference is missing.
        #expect(store.resolve(preferred: .small) == .medium)
        #expect(store.resolve(preferred: nil) == .medium)
        // A preference that is installed always wins.
        #expect(store.resolve(preferred: .large) == .large)

        let small = ModelManifest.spec(for: .small)
        try makeFile(at: paths.models.appendingPathComponent(small.fileName), size: small.byteSize)
        #expect(store.resolve(preferred: .small) == .small)
    }
}

@Test func deleteStalePartFilesRemovesOtherDigests() throws {
    try withTempPaths { paths in
        let spec = ModelManifest.spec(for: .medium)
        let live = paths.models.appendingPathComponent(spec.partFileName)
        let stale = paths.models.appendingPathComponent("muscriptor-medium-f16.gguf.deadbeef.part")
        let otherSize = paths.models.appendingPathComponent("muscriptor-small-f16.gguf.0badcafe.part")
        let unrelated = paths.models.appendingPathComponent("notes.txt")
        for url in [live, stale, otherSize, unrelated] {
            try makeFile(at: url, size: 16)
        }

        ModelStore(paths: paths).deleteStalePartFiles()

        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: otherSize.path))
    }
}
