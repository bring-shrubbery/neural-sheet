import Foundation
import Testing

@testable import NeuralSheetCore

@Test func recordingInputSettingRoundTripsEveryKind() {
    let settings: [RecordingInputSetting] = [
        .device(uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:00008030:8,9"),
        .systemAudio,
        .app(bundleID: "com.apple.Music"),
    ]

    for setting in settings {
        #expect(RecordingInputSetting(encoded: setting.encoded) == setting)
    }

    #expect(RecordingInputSetting.systemAudio.encoded == "system")
    #expect(RecordingInputSetting.app(bundleID: "com.apple.Music").encoded == "app:com.apple.Music")
}

@Test func recordingInputSettingReadsAnythingElseAsTheDefault() {
    for text in ["", "device:", "app:", "system:", "microphone:x", "device", "System"] {
        #expect(RecordingInputSetting(encoded: text) == nil)
    }
}

@Test func globalSettingsRecordingInputRoundTripsAndDefaults() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).settings")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(GlobalSettings().recordingInput == "")

    var settings = GlobalSettings()
    settings.recordingInput = RecordingInputSetting.app(bundleID: "com.apple.Music").encoded
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url) == settings)

    // A file from before the key is the system default.
    let text = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "<key>recordingInput</key>", with: "<key>somethingElse</key>")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(GlobalSettings.load(from: url).recordingInput == "")
}
