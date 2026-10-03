import Foundation
import NeuralSheetCore
import XCTest

@testable import NeuralSheet

/// The document round trip (sub-issue C): a package written by the core package's writer, as the
/// Mac writes it, read through ``NeuralSheetDocument``, written back through it, and read again
/// with the Mac's reader -- the state, the transcription and the audio's bytes all unchanged.
@MainActor
final class DocumentRoundTripTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Through the model: the package is installed into ``MobileModel`` and snapshotted from it,
    /// and the take comes back as the very file wrapper the package was opened with.
    func testPackageRoundTripsThroughTheDocumentAndTheModel() throws {
        let (source, original, audioBytes) = try writeSourcePackage(named: "Song")
        let opened = try FileWrapper(url: source, options: .immediate)

        let document = try NeuralSheetDocument(fileWrapper: opened)
        let model = document.model

        XCTAssertNil(model.loadProblem)
        XCTAssertEqual(model.document?.notes.count, 3)
        XCTAssertEqual(model.editor.key, original.state.key)
        XCTAssertEqual(model.editor.grid.segments.count, 2)

        let snapshot = try document.snapshot(contentType: .neuralSheetProject)
        let saved = try document.fileWrapper(snapshot: snapshot, existingFile: opened)

        // The unchanged take is the opened file's own wrapper: the system's save keeps the file.
        let openedAudio = opened.fileWrappers?["audio"]?.fileWrappers?["take.wav"]
        let savedAudio = saved.fileWrappers?["audio"]?.fileWrappers?["take.wav"]
        XCTAssertNotNil(openedAudio)
        XCTAssertTrue(openedAudio === savedAudio)

        let destination = directory.appendingPathComponent("Saved.neuralsheet", isDirectory: true)
        try saved.write(to: destination, options: [], originalContentsURL: source)

        try assertPackage(at: destination, matches: original, audioBytes: audioBytes)
        try keepForTheMac(destination)
    }

    /// With no existing file to take the audio from (a first save elsewhere), the take is written
    /// from the working copy, byte for byte.
    func testPackageRoundTripsWithoutAnExistingFile() throws {
        let (source, original, audioBytes) = try writeSourcePackage(named: "Fresh")
        let document = try NeuralSheetDocument(fileWrapper: FileWrapper(url: source, options: []))
        _ = document.model

        let snapshot = try document.snapshot(contentType: .neuralSheetProject)
        let saved = try document.fileWrapper(snapshot: snapshot, existingFile: nil)

        let destination = directory.appendingPathComponent("Copy.neuralsheet", isDirectory: true)
        try saved.write(to: destination, options: [], originalContentsURL: nil)

        try assertPackage(at: destination, matches: original, audioBytes: audioBytes)
    }

    /// Saved before the screen has built the model: the package goes back as it was read.
    func testPackageRoundTripsBeforeTheModelIsBuilt() throws {
        let (source, original, audioBytes) = try writeSourcePackage(named: "Unseen")
        let opened = try FileWrapper(url: source, options: .immediate)
        let document = try NeuralSheetDocument(fileWrapper: opened)

        let snapshot = try document.snapshot(contentType: .neuralSheetProject)
        let saved = try document.fileWrapper(snapshot: snapshot, existingFile: opened)

        let destination = directory.appendingPathComponent("Unseen-Saved.neuralsheet", isDirectory: true)
        try saved.write(to: destination, options: [], originalContentsURL: source)

        try assertPackage(at: destination, matches: original, audioBytes: audioBytes)
    }

    /// A new document saves as a package without audio that reads back empty.
    func testNewDocumentSavesAnEmptyPackage() throws {
        let document = NeuralSheetDocument()
        let snapshot = try document.snapshot(contentType: .neuralSheetProject)
        let saved = try document.fileWrapper(snapshot: snapshot, existingFile: nil)

        let destination = directory.appendingPathComponent("Untitled.neuralsheet", isDirectory: true)
        try saved.write(to: destination, options: [], originalContentsURL: nil)

        let read = try ProjectPackage.read(from: destination)
        XCTAssertNil(read.audioURL)
        XCTAssertNil(read.package.transcription)
        XCTAssertEqual(read.package.state.audioFileName, "")
    }

    func testAFileWrapperThatIsNotAPackageIsRefused() {
        let file = FileWrapper(regularFileWithContents: Data("not a package".utf8))

        XCTAssertThrowsError(try NeuralSheetDocument(fileWrapper: file)) { error in
            XCTAssertEqual(error as? ProjectError, .notAPackage)
        }
    }

    // MARK: - Fixtures

    /// A package as the Mac writes it: a short WAV, three notes, a two-segment grid, a key,
    /// chords, markers, a version and a mix, with the view state the model keeps.
    private func writeSourcePackage(named name: String) throws -> (URL, ProjectPackage, Data) {
        let wav = directory.appendingPathComponent("take.wav")
        let audioBytes = Self.wav(seconds: 0.5, rate: 16_000)
        try audioBytes.write(to: wav)

        // The count the model's decoder makes of it, so the notes are kept on install.
        let sampleCount = try AudioFileLoader.load(url: wav, deviceRate: 48_000).mono16k.count

        let raw = [
            NoteEvent(startTime: 0.0, endTime: 0.2, pitch: 60, program: 0),
            NoteEvent(startTime: 0.1, endTime: 0.3, pitch: 64, program: 0),
            NoteEvent(startTime: 0.2, endTime: 0.45, pitch: 67, program: 33),
        ]
        let version = NoteVersion(id: UUID(), name: "Before Transcribe", date: Date(timeIntervalSince1970: 1_000_000), notes: raw)
        let transcription = ProjectTranscription(sourceSampleCount: sampleCount,
                                                 rawNotes: raw,
                                                 document: NoteDocument(events: raw),
                                                 versions: [version])

        var state = ProjectState()
        state.audioFileName = "take.wav"
        state.audioDisplayName = "take"
        state.selectedGroups = [InstrumentGroup.allCases[0].rawValue]
        state.mixer = [0: InstrumentChannelSettings(gainDb: -3, muted: false, soloed: false, pan: 0.25),
                       33: InstrumentChannelSettings(gainDb: 0, muted: true)]
        state.gridSegments = [GridSegment(startBar: 1, bpm: 96),
                              GridSegment(startBar: 5, bpm: 132, timeSignature: TimeSignature(numerator: 3, denominator: 4))]
        state.exportTempo = 96
        state.gridOffsetSeconds = 0.05
        state.gridDivision = .eighth
        state.gridSwing = 0.6
        state.snapEnabled = false
        state.targetProgram = 33
        state.key = MusicalKey(tonic: 9, mode: .minor)
        state.chords = [ChordEvent(seconds: 0, chord: ChordSymbol(root: 9, quality: .minor)), ChordEvent(seconds: 0.25, chord: nil)]
        state.chordsEdited = true
        state.markers = [Marker(seconds: 0, name: "Intro"), Marker(seconds: 0.3, name: "Verse")]
        state.clickEnabled = true
        state.clickGainDb = -12
        state.workspace = .edit
        state.playheadSeconds = 0.2
        state.playheadCentered = false
        state.zoomLevel = 2
        state.verticalZoom = 1.5

        let package = ProjectPackage(state: state, transcription: transcription)
        let url = directory.appendingPathComponent("\(name).neuralsheet", isDirectory: true)
        try package.write(to: url, audioSource: wav)

        return (url, package, audioBytes)
    }

    private func assertPackage(at url: URL, matches original: ProjectPackage, audioBytes: Data,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let read = try ProjectPackage.read(from: url)

        XCTAssertEqual(read.package.state, original.state, file: file, line: line)
        XCTAssertEqual(read.package.transcription, original.transcription, file: file, line: line)
        XCTAssertFalse(read.transcriptionUnreadable, file: file, line: line)

        let audioURL = try XCTUnwrap(read.audioURL, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: audioURL), audioBytes, file: file, line: line)
    }

    /// Leaves a copy where the Mac check can pick it up: the app container's tmp, under a fixed
    /// name (`xcrun simctl get_app_container booted com.quassum.neuralsheet.ios data`).
    private func keepForTheMac(_ url: URL) throws {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("RoundTrip.neuralsheet", isDirectory: true)
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.copyItem(at: url, to: kept)
        print("NeuralSheet round trip: kept \(kept.path)")
    }

    /// A mono 16-bit PCM WAV of a 440 Hz sine.
    private static func wav(seconds: Double, rate: Int) -> Data {
        let frames = Int(seconds * Double(rate))
        var data = Data()

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(frames * 2))

        for frame in 0..<frames {
            let sample = sin(2 * Double.pi * 440 * Double(frame) / Double(rate)) * 0.5
            append(Int16(sample * Double(Int16.max)))
        }

        return data
    }
}
