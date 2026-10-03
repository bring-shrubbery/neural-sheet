import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Pan in the MIDI file

@Test func midiPanMapsTheMixersRangeOntoCC10() {
    #expect(MidiFileWriter.midiPan(-1) == 0)
    #expect(MidiFileWriter.midiPan(0) == 64)
    #expect(MidiFileWriter.midiPan(1) == 127)
    #expect(MidiFileWriter.midiPan(0.5) == 95)
    #expect(MidiFileWriter.midiPan(-3) == 0)
    #expect(MidiFileWriter.midiPan(.nan) == 64)
}

@Test func midiWritesCC10AfterTheProgramChangeOnlyForAPannedTrack() {
    let notes = [
        NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0),
        NoteEvent(startTime: 0, endTime: 1, pitch: 40, program: 33),
        NoteEvent(startTime: 0, endTime: 1, pitch: 72, program: 40),
    ]
    let grid = TempoGrid(bpm: 120)
    let panned = [UInt8](MidiFileWriter.data(notes: notes, grid: grid, mode: .reuseChannels,
                                             pans: [0: -1, 33: 0.5, 40: 0]))

    // Program change then CC 10, both at delta 0, on each track's own channel.
    #expect(containsBytes(panned, [0x00, 0xC0, 0, 0x00, 0xB0, 10, 0]))
    #expect(containsBytes(panned, [0x00, 0xC1, 33, 0x00, 0xB1, 10, 95]))
    #expect(!containsBytes(panned, [0xB2, 10]))

    // A centred mix is byte for byte the file without pans.
    let plain = MidiFileWriter.data(notes: notes, grid: grid, mode: .reuseChannels)
    #expect(MidiFileWriter.data(notes: notes, grid: grid, mode: .reuseChannels, pans: [0: 0, 33: 0]) == plain)
}

private func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard haystack.count >= needle.count else { return false }

    return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
}

// MARK: - Mixer

@Test func channelSettingsFromBeforePanOpenCentred() throws {
    let json = Data(#"{"gainDb":-3,"muted":true,"soloed":false}"#.utf8)
    let settings = try JSONDecoder().decode(InstrumentChannelSettings.self, from: json)

    #expect(settings == InstrumentChannelSettings(gainDb: -3, muted: true, soloed: false, pan: 0))

    let panned = InstrumentChannelSettings(pan: -0.25)
    let roundTrip = try JSONDecoder().decode(InstrumentChannelSettings.self, from: JSONEncoder().encode(panned))
    #expect(roundTrip == panned)
}

@Test func mixerPanIsClampedAndReadBack() {
    var mixer = InstrumentMixerState()
    mixer.setPan(program: 24, pan: 2)
    mixer.setPan(program: 33, pan: -0.4)

    #expect(mixer.pan(program: 24) == 1)
    #expect(mixer.pan(program: 33) == -0.4)
    #expect(mixer.pan(program: 0) == 0)
}
