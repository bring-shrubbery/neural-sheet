import AVFoundation
import Foundation
import NeuralSheetCore
import Testing

// Open in NeuralSheet (Audio Unit design §2): the neuralsheet://open URL the plugin builds and the
// check the app makes of it (HandoffURL, shared by path with the Mac app), and the package the
// plugin writes into the handoff folder.

private let handoff = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/6WCYZER5LX.com.quassum.neuralsheet/Handoff",
                          isDirectory: true)
private let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"

private func package(_ name: String) -> URL {
    handoff.appendingPathComponent(uuid, isDirectory: true).appendingPathComponent(name)
}

private func open(_ path: String) -> URL {
    var components = URLComponents()
    components.scheme = "neuralsheet"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: path)]
    return components.url!
}

@Test func theURLCarriesThePathAndTheCheckGivesItBack() throws {
    for name in ["Bass take.neuralsheet", "Gtr & Vox = 100% #2 + ü.neuralsheet", "a?b=c&path=x.neuralsheet"] {
        let url = try #require(HandoffURL.url(forPackage: package(name)))

        #expect(url.scheme == "neuralsheet")
        #expect(url.host == "open")
        #expect(HandoffURL.package(from: url, handoff: handoff)?.path == package(name).path)
    }
}

@Test func theURLIsPercentEncoded() throws {
    let url = try #require(HandoffURL.url(forPackage: package("A & B.neuralsheet")))
    #expect(url.absoluteString == "neuralsheet://open?path=/Users/someone/Library/Group%20Containers/"
        + "6WCYZER5LX.com.quassum.neuralsheet/Handoff/\(uuid)/A%20%26%20B.neuralsheet")
}

@Test func aPathOutsideTheHandoffFolderIsRefused() {
    let refused = [
        "/Users/someone/Music/Song.neuralsheet",
        "/Users/someone/Library/Group Containers/6WCYZER5LX.com.quassum.neuralsheet/Song.neuralsheet",
        // Directly in Handoff, or one folder too deep.
        handoff.appendingPathComponent("Song.neuralsheet").path,
        package("deeper/Song.neuralsheet").path,
        // Not a uuid folder.
        handoff.appendingPathComponent("not-a-uuid/Song.neuralsheet").path,
        // Climbing out with .. after looking inside.
        handoff.path + "/\(uuid)/../../../../../../etc/Song.neuralsheet",
        handoff.path + "/../Handoff2/\(uuid)/Song.neuralsheet",
        // Not a package, or no name.
        package("Song.wav").path,
        package(".neuralsheet").path,
        // Relative.
        "Handoff/\(uuid)/Song.neuralsheet",
    ]

    for path in refused {
        #expect(HandoffURL.package(from: open(path), handoff: handoff) == nil, "\(path)")
    }
}

@Test func onlyTheOpenURLOfTheSchemeIsAccepted() throws {
    let good = package("Song.neuralsheet").path
    #expect(HandoffURL.package(from: open(good), handoff: handoff) != nil)

    var other = URLComponents(url: open(good), resolvingAgainstBaseURL: false)!
    other.scheme = "file"
    #expect(HandoffURL.package(from: other.url!, handoff: handoff) == nil)

    other = URLComponents(url: open(good), resolvingAgainstBaseURL: false)!
    other.host = "delete"
    #expect(HandoffURL.package(from: other.url!, handoff: handoff) == nil)

    other = URLComponents(url: open(good), resolvingAgainstBaseURL: false)!
    other.queryItems = [URLQueryItem(name: "path", value: good), URLQueryItem(name: "path", value: "/etc/x.neuralsheet")]
    #expect(HandoffURL.package(from: other.url!, handoff: handoff) == nil)

    other.queryItems = []
    #expect(HandoffURL.package(from: other.url!, handoff: handoff) == nil)
    #expect(HandoffURL.package(from: URL(string: "neuralsheet://open")!, handoff: handoff) == nil)
}

@Test func aSymbolicLinkOutOfTheHandoffFolderIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Handoff/\(uuid)", isDirectory: true)
    let outside = root.appendingPathComponent("Elsewhere.neuralsheet", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("Song.neuralsheet")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(HandoffURL.package(from: open(link.path), handoff: root.appendingPathComponent("Handoff")) == nil)
}

// MARK: - The package

@Test func theHandoffPackageIsAProjectTheAppOpens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let left = (0..<48_000).map { Float($0 % 480) / 480 - 0.5 }
    let take = try #require(CapturedTake.make(channels: [left, left.map { -$0 }], sampleRate: 48_000, startSampleTime: 0))
    let notes = [NoteEvent(startTime: 0.1, endTime: 0.4, pitch: 64, program: 0)]
    let transcription = ProjectTranscription(sourceSampleCount: take.source.mono16k.count, rawNotes: notes,
                                             document: NoteDocument(events: notes))
    let state = HandoffWriter.projectState(selectedGroups: [3], mixer: [0: InstrumentChannelSettings(gainDb: -4)])

    let written = try HandoffWriter.write(take: take, transcription: transcription, state: state, name: "Bass",
                                          handoff: root)

    #expect(written.lastPathComponent == "Bass.neuralsheet")
    #expect(UUID(uuidString: written.deletingLastPathComponent().lastPathComponent) != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: written.deletingLastPathComponent().path) == ["Bass.neuralsheet"])
    #expect(HandoffURL.url(forPackage: written).flatMap { HandoffURL.package(from: $0, handoff: root) } != nil)

    let read = try ProjectPackage.read(from: written)
    #expect(read.package.state.selectedGroups == [3])
    #expect(read.package.state.mixer[0]?.gainDb == -4)
    #expect(read.package.transcription == transcription)
    #expect(!read.transcriptionUnreadable)

    // The audio decodes to the take's own samples, so the app's 16 kHz copy has the notes' length.
    let audio = try #require(read.audioURL)
    #expect(audio.lastPathComponent == ProjectPackage.recordingFileName)
    let decoded = try #require(readAudio(audio))
    #expect(decoded.rate == 48_000)
    #expect(decoded.channels == [left, left.map { -$0 }])
    #expect(Resampler.toMono16k(channels: decoded.channels, sourceRate: 48_000).count == transcription.sourceSampleCount)
}

@Test func thePackageIsNamedAfterTheTrack() {
    #expect(HandoffWriter.packageName(trackName: "Bass DI") == "Bass DI")
    #expect(HandoffWriter.packageName(trackName: "Gtr/Vox: L\\R") == "Gtr-Vox- L-R")
    #expect(HandoffWriter.packageName(trackName: "  .hidden  ") == "hidden")
    #expect(HandoffWriter.packageName(trackName: nil) == "NeuralSheet Plugin")
    #expect(HandoffWriter.packageName(trackName: " ") == "NeuralSheet Plugin")
    #expect(HandoffWriter.packageName(trackName: String(repeating: "x", count: 200)).count == 80)
}

/// A file's planar float samples and rate, as the app's loader reads them.
private func readAudio(_ url: URL) -> (channels: [[Float]], rate: Double)? {
    guard let file = try? AVAudioFile(forReading: url),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
        (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
    else { return nil }

    let channels = (0..<Int(file.processingFormat.channelCount)).map {
        Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
    }
    return (channels, file.processingFormat.sampleRate)
}
