import AVFoundation
import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - MixLaw

@Test func mixLawIsEqualPowerAtTheMiddle() {
    let gains = MixLaw.gains(mix: 0.5)

    #expect(abs(gains.original - Float(0.5.squareRoot())) < 1e-6)
    #expect(abs(gains.synth - Float(0.5.squareRoot())) < 1e-6)
    #expect(abs(gains.original * gains.original + gains.synth * gains.synth - 1) < 1e-6)
}

@Test func mixLawEndsAreOneSideAlone() {
    let source = MixLaw.gains(mix: 0)
    let synth = MixLaw.gains(mix: 1)

    #expect(source.original == 1)
    #expect(source.synth == 0)
    #expect(abs(synth.original) < 1e-7)
    #expect(synth.synth == 1)
    // Out of range clamps; NaN is all-source.
    #expect(MixLaw.gains(mix: 2).synth == 1)
    #expect(MixLaw.gains(mix: .nan).original == 1)
}

@Test func mixLawResolvesTheMasterAndTheSplit() {
    let unity = MixLaw.resolve(mix: 0.5, masterGainDb: 0, muted: false, stereoSplit: false, hasNotes: true)
    #expect(unity.master == 1)
    #expect(abs(unity.source - Float(0.5.squareRoot())) < 1e-6)

    // No notes: all source, whatever the mix says.
    let empty = MixLaw.resolve(mix: 1, masterGainDb: 0, muted: false, stereoSplit: false, hasNotes: false)
    #expect(empty.source == 1)
    #expect(empty.synth == 0)

    // The fader's floor and MUTE are silence.
    #expect(MixLaw.resolve(mix: 0, masterGainDb: -36, muted: false, stereoSplit: false, hasNotes: true).source == 0)
    #expect(MixLaw.resolve(mix: 0, masterGainDb: 0, muted: true, stereoSplit: false, hasNotes: true).master == 0)

    // −6 dB.
    let quiet = MixLaw.resolve(mix: 0, masterGainDb: -6, muted: false, stereoSplit: false, hasNotes: true)
    #expect(abs(quiet.source - Float(pow(10.0, -6.0 / 20))) < 1e-6)

    // The split: both at full, a hold silences the other ear.
    let split = MixLaw.resolve(mix: 0.5, masterGainDb: 0, muted: false, stereoSplit: true, hasNotes: true)
    #expect(split.source == 1 && split.synth == 1 && split.stereoSplit)
    #expect(MixLaw.resolve(mix: 1, masterGainDb: 0, muted: false, stereoSplit: true, hasNotes: true).source == 0)
    #expect(MixLaw.resolve(mix: 0, masterGainDb: 0, muted: false, stereoSplit: true, hasNotes: true).synth == 0)
}

// MARK: - Formats

@Test func audioExportFormatsNameTheirFiles() {
    #expect(AudioExportFormat.wav24.fileExtension == "wav")
    #expect(AudioExportFormat.aiff24.fileExtension == "aiff")
    #expect(AudioExportFormat.m4a.fileExtension == "m4a")
    #expect(AudioExportFormat.aiff24.fileName(takeName: "Song") == "Song.aiff")
    #expect(AudioExportFormat.wav24.fileName(takeName: "a/b:c") == "a-b-c.wav")
}

@Test func audioExportFormatSettingsAreWhatAVAudioFileReads() throws {
    // The keys are spelled out in the package; they have to be AVFoundation's own.
    let wav = AudioExportFormat.wav24.fileSettings(sampleRate: 48000, channels: 2)
    #expect(wav[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
    #expect(wav[AVLinearPCMBitDepthKey] as? Int == 24)
    #expect(wav[AVLinearPCMIsFloatKey] as? Bool == false)
    #expect(wav[AVLinearPCMIsBigEndianKey] as? Bool == false)
    #expect(wav[AVSampleRateKey] as? Double == 48000)
    #expect(wav[AVNumberOfChannelsKey] as? Int == 2)

    #expect(AudioExportFormat.aiff24.fileSettings(sampleRate: 44100, channels: 2)[AVLinearPCMIsBigEndianKey] as? Bool == true)

    let m4a = AudioExportFormat.m4a.fileSettings(sampleRate: 44100, channels: 2)
    #expect(m4a[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
    #expect(m4a[AVEncoderBitRateKey] as? Int == 256_000)

    // Each opens for writing, the format descriptors being ones Core Audio accepts.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for format in AudioExportFormat.allCases {
        let url = directory.appendingPathComponent(format.fileName(takeName: "t"))
        let file = try AVAudioFile(forWriting: url, settings: format.fileSettings(sampleRate: 44100, channels: 2),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.fileFormat.channelCount == 2)
        if format != .m4a { #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24) }
    }
}

// MARK: - Spec and tail

@Test func renderSpecStopsMidiOnlyAtTheLastNote() {
    let notes: [(start: Double, end: Double)] = [(1, 2), (3, 7.5), (12, 13)]

    let midi = RenderSpec(what: .midi, range: 0 ... 10, format: .wav24)
    #expect(midi.transportEnd(notes: notes) == 7.5)

    // A note running past the range is cut at it.
    #expect(RenderSpec(what: .midi, range: 0 ... 5, format: .wav24).transportEnd(notes: notes) == 5)

    // No notes in range: the range.
    #expect(RenderSpec(what: .midi, range: 8 ... 11, format: .wav24).transportEnd(notes: notes) == 11)

    // The mixes run the range.
    #expect(RenderSpec(what: .mixAsHeard, range: 0 ... 10, format: .wav24).transportEnd(notes: notes) == 10)
    #expect(RenderSpec(what: .original, range: 0 ... 10, format: .wav24).transportEnd(notes: notes) == 10)
}

@Test func renderTailEndsBelowMinus90() {
    #expect(RenderTail.isSilent(peak: 0))
    #expect(RenderTail.isSilent(peak: 3e-5))
    #expect(!RenderTail.isSilent(peak: 4e-5))
    #expect(RenderTail.maxFrames(sampleRate: 48000) == 96000)
}

// MARK: - Stem names

@Test func stemNamesAreTheSpecs() {
    #expect(StemNames.exportOrder.map { StemNames.displayNames[$0] } == ["Drums", "Bass", "Vocals", "Other"])
    #expect(StemNames.cacheFileName(stem: 0) == "Drums.caf")
    #expect(StemNames.cacheFileName(stem: 3) == "Vocals.caf")
    #expect(StemNames.exportFileName(takeName: "My Song", stem: 1) == "My Song - Bass.wav")
    #expect(StemNames.exportFileName(takeName: "  ", stem: 2) == "Recording - Other.wav")
}

// MARK: - Settings

@Test func globalSettingsAudioExportRoundTripsAndDefaults() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("audioexport-\(UUID().uuidString).settings")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(GlobalSettings().audioExportWhat == .midi)
    #expect(GlobalSettings().audioExportFormat == .wav24)
    #expect(!GlobalSettings().audioExportMarkedRange)

    var settings = GlobalSettings()
    settings.audioExportWhat = .mixAsHeard
    settings.audioExportFormat = .m4a
    settings.audioExportMarkedRange = true
    try settings.save(to: url)
    #expect(GlobalSettings.load(from: url) == settings)

    // An unknown value from a later version falls back without losing the rest of the file.
    let text = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "<string>m4a</string>", with: "<string>flac</string>")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let loaded = GlobalSettings.load(from: url)
    #expect(loaded.audioExportFormat == .wav24)
    #expect(loaded.audioExportWhat == .mixAsHeard)
}
