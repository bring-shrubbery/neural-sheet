import Foundation
import Testing

@testable import NeuralSheetCore

// Pitch curves as MIDI pitch bend (pitch curves design §2, MIDI), byte for byte.

/// The instrument tracks' bodies (every `MTrk` after the conductor).
private func instrumentTracks(_ data: Data) -> [[UInt8]] {
    let bytes = [UInt8](data)
    var tracks: [[UInt8]] = []
    var index = 14

    while index + 8 <= bytes.count {
        let length = bytes[(index + 4)..<(index + 8)].reduce(0) { $0 << 8 | Int($1) }
        tracks.append(Array(bytes[(index + 8)..<(index + 8 + length)]))
        index += 8 + length
    }

    return Array(tracks.dropFirst())
}

private let pianoHeader: [UInt8] = [0x00, 0xFF, 0x03, 0x05, 0x50, 0x69, 0x61, 0x6E, 0x6F, 0x00, 0xC0, 0x00]
private let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

@Test func aMonophonicTrackCarriesTheBendRangeAndItsBends() {
    // At 120 BPM a second is 1920 ticks and a frame 19.2. Frame 1 (+10 ¢) and frame 3 (+20 ¢)
    // move 5 ¢ or more from the last written value; frame 0 (0 ¢) and frame 2 (+12 ¢) do not.
    let note = NoteEvent(startTime: 0.5, endTime: 0.54, pitch: 60, program: 0, pitchCurve: [0, 10, 12, 20])
    let data = MidiFileWriter.data(notes: [note], bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)

    let expected: [UInt8] = pianoHeader + [
        // RPN 0 (CC 101 = 0, CC 100 = 0), data entry 2 semitones (CC 6 = 2, CC 38 = 0).
        0x00, 0xB0, 0x65, 0x00,
        0x00, 0xB0, 0x64, 0x00,
        0x00, 0xB0, 0x06, 0x02,
        0x00, 0xB0, 0x26, 0x00,
        // Note on at tick 960.
        0x87, 0x40, 0x90, 0x3C, 0x64,
        // +10 ¢ at tick 979 (0.51 s): 8192 + 409.55 → 8602 = 0x43 << 7 | 0x1A.
        0x13, 0xE0, 0x1A, 0x43,
        // +20 ¢ at tick 1018 (0.53 s): 8192 + 819.1 → 9011 = 0x46 << 7 | 0x33.
        0x27, 0xE0, 0x33, 0x46,
        // Note off at tick 1037 (0.54 s), then the recentre: 8192 = 0x40 << 7.
        0x13, 0x80, 0x3C, 0x00,
        0x00, 0xE0, 0x00, 0x40,
    ] + endOfTrack

    #expect(instrumentTracks(data) == [expected])
}

@Test func anOpeningBendComesBeforeTheNoteOn() {
    let note = NoteEvent(startTime: 0.5, endTime: 0.52, pitch: 60, program: 0, pitchCurve: [-200, -200])
    let track = instrumentTracks(MidiFileWriter.data(notes: [note], bpm: 120, startOffsetSeconds: 0,
                                                     mode: .reuseChannels))[0]

    // −200 ¢ is the bottom of the range: 8192 − 8191 = 1.
    let opening = track.firstRange(of: [0x87, 0x40, 0xE0, 0x01, 0x00, 0x00, 0x90, 0x3C, 0x64])
    #expect(opening != nil)
}

@Test func curvesBeyondTheRangeClamp() {
    #expect(MidiFileWriter.bendValue(cents: 500) == 16383)
    #expect(MidiFileWriter.bendValue(cents: -500) == 1)
    #expect(MidiFileWriter.bendValue(cents: 0) == 8192)
    #expect(MidiFileWriter.bendValue(cents: 200) == 16383)
}

@Test func anOverlappingTrackGetsNoBends() {
    let notes = [
        NoteEvent(startTime: 0.5, endTime: 1, pitch: 60, program: 0, pitchCurve: [0, 30, 60]),
        NoteEvent(startTime: 0.5, endTime: 1, pitch: 64, program: 0),
    ]
    let track = instrumentTracks(MidiFileWriter.data(notes: notes, bpm: 120, startOffsetSeconds: 0,
                                                     mode: .reuseChannels))[0]

    #expect(!track.contains(0xE0))
    #expect(!track.contains(0xB0))
}

@Test func aTrackWithoutCurvesIsUnchanged() {
    let notes = [NoteEvent(startTime: 0.5, endTime: 1, pitch: 60, program: 0)]
    let track = instrumentTracks(MidiFileWriter.data(notes: notes, bpm: 120, startOffsetSeconds: 0,
                                                     mode: .reuseChannels))[0]

    #expect(track == pianoHeader + [0x87, 0x40, 0x90, 0x3C, 0x64, 0x87, 0x40, 0x80, 0x3C, 0x00] + endOfTrack)
}

@Test func touchingNotesAreMonophonicAndEachRecentres() {
    let notes = [
        NoteEvent(startTime: 0.5, endTime: 0.52, pitch: 60, program: 0, pitchCurve: [50, 50]),
        NoteEvent(startTime: 0.52, endTime: 0.54, pitch: 62, program: 0, pitchCurve: [0, 0]),
    ]

    #expect(MidiFileWriter.isMonophonic(notes))

    let bends = MidiFileWriter.bends(for: notes, channelBits: 0, tick: { Int(($0 * 1920).rounded()) }).events
    // The first note's opening bend and its recentre; the flat second note writes nothing.
    #expect(bends.map(\.bytes) == [[0xE0, 0x00, 0x50], [0xE0, 0x00, 0x40]])
}
