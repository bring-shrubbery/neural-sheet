import Foundation
import Testing

@testable import NeuralSheetCore

// *Open in NeuralSheet* (Audio Unit design §2): the handoff folder in the group container, its
// sweep, and the move of a handed-off package into the user's Music folder.

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePaths(in directory: URL, group: Bool = true) -> AppPaths {
    AppPaths(
        root: directory.appendingPathComponent("root", isDirectory: true),
        secondaryModels: directory.appendingPathComponent("secondary", isDirectory: true),
        music: directory.appendingPathComponent("music", isDirectory: true),
        groupContainer: group ? directory.appendingPathComponent("group", isDirectory: true) : nil)
}

/// A minimal package written as the plugin writes one: `<handoff>/<uuid>/<name>.neuralsheet`.
private func writeHandoff(_ paths: AppPaths, name: String, uuid: UUID = UUID()) throws -> URL {
    let handoff = try #require(paths.handoff)
    let package = handoff.appendingPathComponent(uuid.uuidString, isDirectory: true)
        .appendingPathComponent(name).appendingPathExtension(ProjectPackage.pathExtension)
    try ProjectPackage(state: ProjectState(), transcription: nil).write(to: package, audioSource: nil)
    return package
}

private func setModified(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@Test func theHandoffFolderIsInTheGroupContainerAndTheProjectsInMusic() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)

    #expect(paths.handoff == directory.appendingPathComponent("group/Handoff", isDirectory: true))
    #expect(paths.handoffProjects == directory.appendingPathComponent("music/NeuralSheet", isDirectory: true))
    #expect(makePaths(in: directory, group: false).handoff == nil)
}

@Test func adoptingAHandoffMovesThePackageAndRemovesItsFolder() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    let package = try writeHandoff(paths, name: "Bass take")

    let adopted = try paths.adoptHandoff(package)

    #expect(adopted.path == paths.handoffProjects.appendingPathComponent("Bass take.neuralsheet").path)
    #expect(try ProjectPackage.read(from: adopted).package.state == ProjectState())
    #expect(!FileManager.default.fileExists(atPath: package.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: try #require(paths.handoff).path))
}

@Test func adoptingAHandoffNumbersTheNameWhenTaken() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)

    let first = try paths.adoptHandoff(try writeHandoff(paths, name: "Take"))
    let second = try paths.adoptHandoff(try writeHandoff(paths, name: "Take"))
    let third = try paths.adoptHandoff(try writeHandoff(paths, name: "Take"))

    #expect(first.lastPathComponent == "Take.neuralsheet")
    #expect(second.lastPathComponent == "Take 2.neuralsheet")
    #expect(third.lastPathComponent == "Take 3.neuralsheet")
}

@Test func adoptingAMissingPackageThrows() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    let missing = try #require(paths.handoff).appendingPathComponent("\(UUID().uuidString)/Gone.neuralsheet")

    #expect(throws: ProjectError.self) { try paths.adoptHandoff(missing) }
}

@Test func theSweepRemovesHandoffsOlderThanADayOnly() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    let now = Date()

    let stale = try writeHandoff(paths, name: "Old").deletingLastPathComponent()
    let fresh = try writeHandoff(paths, name: "New").deletingLastPathComponent()
    try setModified(stale, now.addingTimeInterval(-AppPaths.handoffLifetime - 60))
    try setModified(fresh, now.addingTimeInterval(-AppPaths.handoffLifetime + 60))

    paths.sweepHandoff(now: now)

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

@Test func theSweepIsQuietWithoutAHandoffFolder() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    makePaths(in: directory).sweepHandoff()
    makePaths(in: directory, group: false).sweepHandoff()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("group").path))
}
