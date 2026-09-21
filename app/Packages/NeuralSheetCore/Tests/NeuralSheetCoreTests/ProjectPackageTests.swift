import Foundation
import Testing

@testable import NeuralSheetCore

private func makePackageTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeAudio(in directory: URL, name: String = "take.wav", bytes: String = "RIFF-not-really") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(bytes.utf8).write(to: url)
    return url
}

private func makePackage(audioFileName: String, withTranscription: Bool) -> ProjectPackage {
    var state = ProjectState()
    state.audioFileName = audioFileName
    state.audioDisplayName = audioFileName.isEmpty ? nil : "take"
    state.exportTempo = 100

    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)]
    let transcription = withTranscription
        ? ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw))
        : nil

    return ProjectPackage(state: state, transcription: transcription)
}

@Test func packageRoundTripsWithAudioAndTranscription() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    let package = makePackage(audioFileName: "take.wav", withTranscription: true)
    try package.write(to: url, audioSource: audio)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.state == package.state)
    #expect(read.package.transcription == package.transcription)
    #expect(read.transcriptionUnreadable == false)
    let audioURL = try #require(read.audioURL)
    #expect(audioURL == ProjectPackage.audioURL(in: url, fileName: "take.wav"))
    #expect(try Data(contentsOf: audioURL) == Data("RIFF-not-really".utf8))
}

@Test func packageWithoutATranscriptionHasNoTranscriptionFile() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)

    #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("transcription.json").path))
    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription == nil)
    #expect(read.transcriptionUnreadable == false)
}

@Test func packageWithoutAudioReadsBackWithNoAudioURL() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Empty.neuralsheet")

    try makePackage(audioFileName: "", withTranscription: false).write(to: url, audioSource: nil)

    let read = try ProjectPackage.read(from: url)
    #expect(read.audioURL == nil)
    #expect(read.package.state.audioFileName == "")
}

@Test func packageWriteReplacesAnExistingPackage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)
    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription == nil)
    #expect(read.audioURL != nil)
}

@Test func packageWriteCopiesAudioFromInsideTheDestination() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)
    try FileManager.default.removeItem(at: audio)

    // The unchanged-audio case: the source is the package's own copy.
    let inside = ProjectPackage.audioURL(in: url, fileName: "take.wav")
    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: inside)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription != nil)
    #expect(try Data(contentsOf: #require(read.audioURL)) == Data("RIFF-not-really".utf8))
}

@Test func packageWriteFailureLeavesThePreviousPackageIntact() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)

    let missing = directory.appendingPathComponent("gone.wav")
    #expect(throws: ProjectError.self) {
        try makePackage(audioFileName: "gone.wav", withTranscription: false).write(to: url, audioSource: missing)
    }

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription != nil)
    #expect(read.package.state.audioFileName == "take.wav")
    // No temporary directory is left beside it.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(siblings.sorted() == ["Song.neuralsheet", "take.wav"])
}

@Test func packageReadRefusesWhatIsNotAPackage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let plainFile = directory.appendingPathComponent("Song.neuralsheet")
    try Data("x".utf8).write(to: plainFile)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: plainFile) }

    let wrongExtension = directory.appendingPathComponent("Song.txt", isDirectory: true)
    try FileManager.default.createDirectory(at: wrongExtension, withIntermediateDirectories: true)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: wrongExtension) }

    let emptyFolder = directory.appendingPathComponent("Empty.neuralsheet", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: emptyFolder) }
}

@Test func packageReadReportsUnreadableState() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Song.neuralsheet", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url.appendingPathComponent("project.json"))

    #expect(throws: ProjectError.self) { try ProjectPackage.read(from: url) }

    do {
        _ = try ProjectPackage.read(from: url)
    } catch let ProjectError.unreadable(reason) {
        #expect(!reason.isEmpty)
    }
}

@Test func packageReadReportsMissingAudio() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)
    try FileManager.default.removeItem(at: ProjectPackage.audioURL(in: url, fileName: "take.wav"))

    #expect(throws: ProjectError.missingAudio) { try ProjectPackage.read(from: url) }
}

@Test func packageReadKeepsTheRestWhenTheTranscriptionIsGarbage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)
    try Data("5".utf8).write(to: url.appendingPathComponent("transcription.json"))

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription == nil)
    #expect(read.package.state.exportTempo == 100)
    #expect(read.transcriptionUnreadable == true)
}

@Test func packageReadReportsNothingAtTheURL() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let gone = directory.appendingPathComponent("Deleted.neuralsheet", isDirectory: true)
    #expect(throws: ProjectError.notFound) { try ProjectPackage.read(from: gone) }
}
