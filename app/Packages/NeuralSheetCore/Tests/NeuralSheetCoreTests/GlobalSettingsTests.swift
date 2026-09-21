import Foundation
import Testing

@testable import NeuralSheetCore

/// A fresh directory under the system temp area. Never the user's real Library.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func globalSettingsDefaultsMatchTheApp() {
    let settings = GlobalSettings()

    #expect(settings.modelSize == .medium)
    #expect(settings.editorScale == 1.0)
    #expect(settings.tooltipsVisible)
    #expect(settings.midiOverflowMode == .reuseChannels)
}

@Test func globalSettingsRoundTripThroughAFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("global.settings")

    var settings = GlobalSettings()
    settings.modelSize = .large
    settings.editorScale = 1.25
    settings.tooltipsVisible = false
    settings.midiOverflowMode = .dropExtraInstruments

    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url) == settings)
}

@Test func globalSettingsMissingFileGivesDefaults() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("does-not-exist.settings")

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(GlobalSettings.load(from: url) == GlobalSettings())
}

@Test func globalSettingsCorruptFileGivesDefaults() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("global.settings")
    try Data("not a property list at all".utf8).write(to: url)

    #expect(GlobalSettings.load(from: url) == GlobalSettings())
}

@Test func globalSettingsMissingKeyFallsBackToItsDefault() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("global.settings")
    // Only `editorScale` is present: the other three keys must read as their defaults.
    let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>editorScale</key>
            <real>1.5</real>
        </dict>
        </plist>
        """
    try Data(plist.utf8).write(to: url)

    let loaded = GlobalSettings.load(from: url)

    #expect(loaded.editorScale == 1.5)
    #expect(loaded.modelSize == .medium)
    #expect(loaded.tooltipsVisible)
    #expect(loaded.midiOverflowMode == .reuseChannels)
}

@Test func globalSettingsSaveWritesEveryKeyAsXml() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("global.settings")
    try GlobalSettings().save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("<?xml"))
    #expect(text.contains("<key>modelSize</key>"))
    #expect(text.contains("<key>editorScale</key>"))
    #expect(text.contains("<key>tooltipsVisible</key>"))
    #expect(text.contains("<key>midiOverflowMode</key>"))
    #expect(text.contains("<string>medium</string>"))
}

@Test func globalSettingsSaveReplacesAPreviousFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("global.settings")

    var settings = GlobalSettings()
    settings.modelSize = .small
    try settings.save(to: url)

    settings.modelSize = .large
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url).modelSize == .large)
}

@Test func globalSettingsHiddenRecentProjectsRoundTripAndDefaultEmpty() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("global.settings")

    #expect(GlobalSettings().hiddenRecentProjects.isEmpty)

    var settings = GlobalSettings()
    settings.hiddenRecentProjects = ["/Users/me/Music/Song.neuralsheet"]
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url).hiddenRecentProjects == ["/Users/me/Music/Song.neuralsheet"])
}
