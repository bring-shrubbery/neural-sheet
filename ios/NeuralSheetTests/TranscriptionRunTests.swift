import Foundation
import NeuralSheetCore
import XCTest

@testable import NeuralSheet

/// A whole run on the device (sub-issue D): the bundled test take imported into a model and
/// transcribed with the small model through the Mac's engine, staging and landing. Needs the
/// checkpoint in the app's container, which tests never download (CLAUDE.md): copy
/// `muscriptor-small-f16.gguf` into the simulator's `Library/Application Support/NeuralSheet/models`
/// to run it; without it the test is skipped.
@MainActor
final class TranscriptionRunTests: XCTestCase {
    func testTheBundledTakeTranscribesWithTheSmallModel() async throws {
        let library = ModelLibrary.shared
        library.rescan()

        guard library.path(for: .small) != nil else {
            throw XCTSkip("The small model is not installed in \(AppPaths.standard.models.path); copy muscriptor-small-f16.gguf there to run this test.")
        }

        let saved = AppSettings.shared.settings
        defer { AppSettings.shared.settings = saved }

        AppSettings.shared.settings.separateStems = false
        AppSettings.shared.settings.minimumNoteLength = 0
        AppSettings.shared.settings.minimumConfidence = 0

        let take = try XCTUnwrap(Bundle.main.url(forResource: "test-take", withExtension: "wav"))
        let model = MobileModel()
        model.setModelSize(.small)
        model.importFile(at: take, securityScoped: false)

        try await waitWhile(timeout: 10) { model.isImporting }
        let source = try XCTUnwrap(model.source)
        XCTAssertGreaterThanOrEqual(source.mono16k.count, TranscriptionPlan.minimumSamples)
        XCTAssertTrue(model.canTranscribe)

        model.launchTranscription()
        XCTAssertTrue(model.isRunning)

        try await waitWhile(timeout: 180) { model.isRunning }

        let document = try XCTUnwrap(model.document, "the run landed no document; alert: \(model.alert?.message ?? "none")")
        XCTAssertNil(model.alert)

        print("NeuralSheet test: \(document.notes.count) notes from the test take in "
              + String(format: "%.2f s", model.lastRunSeconds ?? 0))
    }

    /// The engine package's fixture (15 s of a CC BY song) through the app's run: the raw notes
    /// that land are the engine oracle's for the small model, so the iOS run decodes what the
    /// Mac's does. The fixture is read from the repository by path, which the simulator can
    /// reach; elsewhere the test is skipped.
    func testTheEngineFixtureLandsTheOraclesNotes() async throws {
        let library = ModelLibrary.shared
        library.rescan()

        guard library.path(for: .small) != nil else {
            throw XCTSkip("The small model is not installed in \(AppPaths.standard.models.path).")
        }

        let engineTests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures")
        let fixture = engineTests.appendingPathComponent("audio/fixture_3chunks_16k.wav")
        let oracle = engineTests.appendingPathComponent("oracle/small-metal/notes_prelude.json")

        guard FileManager.default.fileExists(atPath: fixture.path),
            let data = try? Data(contentsOf: oracle),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oracleNotes = json["notes"] as? [[String: Any]]
        else {
            throw XCTSkip("The engine fixtures are not reachable from here.")
        }

        let saved = AppSettings.shared.settings
        defer { AppSettings.shared.settings = saved }

        AppSettings.shared.settings.separateStems = false
        AppSettings.shared.settings.minimumNoteLength = 0
        AppSettings.shared.settings.minimumConfidence = 0

        // The fixture's own samples, as the oracle saw them: the loader's decode and its 16 kHz
        // conversion move even a 16 kHz file by a few hundred samples.
        let samples = try Self.floatWAVSamples(at: fixture)
        XCTAssertEqual(samples.count, 240_000)

        let model = MobileModel()
        let peaks = WaveformPeaks()
        peaks.build(from: samples)
        model.installSource(SourceAudio(deviceRate: 16_000, channels: [samples], mono16k: samples, peaks: peaks,
                                        droppedFileName: "fixture", sourcePath: fixture))
        model.setModelSize(.small)

        model.launchTranscription()
        try await waitWhile(timeout: 300) { model.isRunning }

        let document = try XCTUnwrap(model.document, "the run landed no document; alert: \(model.alert?.message ?? "none")")

        print("NeuralSheet test: fixture \(model.rawNotes.count) raw notes (oracle \(oracleNotes.count)), "
              + "\(document.notes.count) in the document, in " + String(format: "%.2f s", model.lastRunSeconds ?? 0))

        // The prelude variant: the engine's default options, which are what a run uses.
        XCTAssertEqual(model.rawNotes.count, oracleNotes.count)

        for (note, expected) in zip(model.rawNotes, oracleNotes) {
            XCTAssertEqual(note.pitch, expected["pitch"] as? Int)
            XCTAssertEqual(note.program, expected["program"] as? Int)
            XCTAssertEqual(note.startTime, expected["onset"] as? Double ?? -1, accuracy: 1e-6)
            XCTAssertEqual(note.endTime, expected["offset"] as? Double ?? -1, accuracy: 1e-6)
        }
    }

    /// The samples of a mono 32-bit float WAV, read from its `data` chunk as they are.
    private static func floatWAVSamples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12

        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })

            if id == "data" {
                return data[offset + 8..<min(offset + 8 + size, data.count)].withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
            }

            offset += 8 + size + (size & 1)
        }

        throw CocoaError(.fileReadCorruptFile)
    }

    private func waitWhile(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(timeout) s")
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
