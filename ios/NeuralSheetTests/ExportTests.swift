import AVFoundation
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers
import XCTest

@testable import NeuralSheet

/// The exports through the model's contract (sub-issue I): MIDI, MusicXML and PDF written under
/// the Mac's names with the right magic bytes, the MIDI reading back note for note; the shared
/// offline render on iOS producing a file of the take's length; the iPad drag's file
/// representation (XCUITest cannot drive a drag between apps, so it is loaded here as a receiver
/// would); and a `.mid` dropped on the roll landing as the transcription or after Replace / Add.
@MainActor
final class ExportTests: XCTestCase {
    private let notes = [
        NoteEvent(startTime: 0.25, endTime: 0.75, pitch: 60, program: 0),
        NoteEvent(startTime: 0.75, endTime: 1.25, pitch: 64, program: 0),
        NoteEvent(startTime: 1.0, endTime: 1.5, pitch: 40, program: 33),
    ]

    private var models: [MobileModel] = []

    override func tearDown() {
        for model in models { model.closeExports() }
        models = []
        super.tearDown()
    }

    /// Two seconds of a quiet 220 Hz tone at 48 kHz, named "fixture", with three notes.
    private func makeModel(withNotes: Bool = true) -> MobileModel {
        let rate = 48_000.0
        let tone = (0..<Int(2 * rate)).map { Float(sin(2 * Double.pi * 220 * Double($0) / rate)) * 0.1 }
        let take = SourceAudio(deviceRate: rate, channels: [tone], mono16k: [Float](repeating: 0, count: 2 * 16_000),
                               peaks: WaveformPeaks(), droppedFileName: "fixture", sourcePath: nil)
        let model = MobileModel()
        model.installSource(take)
        if withNotes { model.installDocument(rawNotes: notes) }
        models.append(model)
        return model
    }

    private func prefix(_ url: URL, _ count: Int, from offset: Int = 0) throws -> String {
        let data = try Data(contentsOf: url)
        return String(decoding: data.dropFirst(offset).prefix(count), as: UTF8.self)
    }

    // MARK: - MIDI, MusicXML, PDF

    func testMIDIIsWrittenUnderTheMacNameAndReadsBack() throws {
        let model = makeModel()
        let url = try model.writeExport(.midi)

        XCTAssertEqual(url.lastPathComponent, MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: "fixture"))
        XCTAssertEqual(try prefix(url, 4), "MThd")
        XCTAssertEqual(try MidiFileReader.read(url: url).allNotes.count, model.document?.notes.count)
    }

    func testMusicXMLAndPDFHaveTheirMagic() throws {
        let model = makeModel()

        let xml = try model.writeExport(.musicXML)
        XCTAssertEqual(xml.pathExtension, "musicxml")
        XCTAssertEqual(try prefix(xml, 5), "<?xml")

        let pdf = try model.writeExport(.pdf)
        XCTAssertEqual(pdf.lastPathComponent, PDFExport.fileName(sourceFileNameWithoutExtension: "fixture"))
        XCTAssertEqual(try prefix(pdf, 4), "%PDF")
    }

    func testTheMenuExportIsReadyAndDoneRemovesIt() throws {
        let model = makeModel()

        model.export(.midi)
        let ready = try XCTUnwrap(model.exports.ready)
        XCTAssertTrue(model.exports.isSheetShown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.files[0].path))

        model.dismissExport()
        XCTAssertNil(model.exports.ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.folder.path))
    }

    func testNothingToExportWithoutNotes() {
        let model = makeModel(withNotes: false)

        XCTAssertFalse(model.canExport)
        XCTAssertNil(model.exportData(.midi))
        XCTAssertTrue(model.canExportAudio)
        XCTAssertFalse(model.canExportAudioMidi)
    }

    // MARK: - Audio

    private func renderAudio(_ model: MobileModel, _ choice: ExportCommands.AudioChoice) async throws -> URL {
        model.startAudioExport(choice)
        let task = try XCTUnwrap(model.exports.audioRender?.task)
        await task.value
        // The finish hops to the main actor after the task's body.
        for _ in 0..<100 where model.exports.ready == nil && model.exports.failure == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.exports.failure?.message)
        return try XCTUnwrap(model.exports.ready?.files.first)
    }

    func testTheOriginalRendersToTheTakesLength() async throws {
        let saved = AppSettings.shared.settings
        defer { AppSettings.shared.settings = saved }

        let model = makeModel()
        let url = try await renderAudio(model, .init(what: .original, markedRange: false, format: .wav24))

        XCTAssertEqual(url.lastPathComponent, "fixture.wav")
        XCTAssertEqual(try prefix(url, 4), "RIFF")
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 96_000)
    }

    func testTheMIDIRendersThroughTheOfflineSynthsAsAAC() async throws {
        let saved = AppSettings.shared.settings
        defer { AppSettings.shared.settings = saved }

        let model = makeModel()
        let url = try await renderAudio(model, .init(what: .midi, markedRange: false, format: .m4a))

        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(try prefix(url, 4, from: 4), "ftyp")
        // To the last note-off, then its release tail of at most 2 s.
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThanOrEqual(seconds, 1.5 - 0.05)
        XCTAssertLessThanOrEqual(seconds, 1.5 + RenderTail.maxSeconds + 0.1)
    }

    func testCancelRemovesTheRender() {
        let saved = AppSettings.shared.settings
        defer { AppSettings.shared.settings = saved }

        let model = makeModel()
        model.startAudioExport(.init(what: .mixAsHeard, markedRange: false, format: .wav24))
        let folder = model.exports.audioRender?.folder

        model.cancelAudioExport()
        XCTAssertNil(model.exports.audioRender)
        XCTAssertFalse(folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    // MARK: - The iPad drag

    func testTheDragCarriesTheMIDIFileWrittenOnDemand() async throws {
        let model = makeModel()
        let provider = try XCTUnwrap(model.dragItemProvider(musicXML: false))

        XCTAssertEqual(provider.suggestedName, model.exportFileName(.midi))
        XCTAssertTrue(provider.registeredContentTypes.contains(.midi))

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: .midi) { url, _, error in
                if let url, let data = try? Data(contentsOf: url) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }

        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "MThd")
        XCTAssertNotNil(model.dragItemProvider(musicXML: true)?.registeredContentTypes.first { $0.conforms(to: .xml) })
    }

    // MARK: - A dropped MIDI file

    func testADroppedMIDIFileBecomesTheTranscriptionOrIsAdded() throws {
        // An octave up, so Add has notes of its own to add.
        let higher = notes.map { var note = $0; note.pitch += 12; return note }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("higher-\(UUID().uuidString).mid")
        try ExportCommands.midiData(notes: higher, editor: EditorState(), mixer: InstrumentMixerState(), mode: .reuseChannels)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let bare = makeModel(withNotes: false)
        bare.importDropped(file)
        XCTAssertEqual(bare.document?.notes.count, notes.count)

        let transcribed = makeModel()
        transcribed.importDropped(file)
        XCTAssertEqual(transcribed.exports.pendingMIDI?.notes.count, notes.count)

        transcribed.resolveMIDIImport(replacing: false)
        XCTAssertNil(transcribed.exports.pendingMIDI)
        XCTAssertEqual(transcribed.document?.notes.count, 2 * notes.count)
        XCTAssertEqual(transcribed.editor.selection.count, notes.count)
    }

    func testAnUnreadableMIDIFileSaysSo() throws {
        let model = makeModel()
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).mid")
        try Data("not midi".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        model.importMIDI(url: junk)
        XCTAssertEqual(model.alert?.title, MIDIImportCommands.failedTitle)
        XCTAssertEqual(model.document?.notes.count, notes.count)
    }
}
