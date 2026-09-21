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
        temp: directory.appendingPathComponent("temp", isDirectory: true),
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
