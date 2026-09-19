import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

private func note(
    _ start: Double, _ end: Double, pitch: Int, program: Int = 0,
    amplitude: Double = NoteEvent.defaultAmplitude
) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

/// The file split into its `MThd`/`MTrk` chunks, so a test can talk about "track 1" rather than
/// about an offset into a byte blob.
private func chunks(_ data: Data) -> [(type: String, body: [UInt8])] {
    let bytes = [UInt8](data)
    var result: [(type: String, body: [UInt8])] = []
    var i = 0

    while i + 8 <= bytes.count {
        let type = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
        var length = 0
        for byte in bytes[(i + 4)..<(i + 8)] { length = length << 8 | Int(byte) }
        let start = i + 8
        let end = min(start + length, bytes.count)
        result.append((type, Array(bytes[start..<end])))
        i = end
    }

    return result
}

private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    indexOf(haystack, needle) != nil
}

private func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }

    for start in 0...(haystack.count - needle.count)
    where Array(haystack[start..<(start + needle.count)]) == needle {
        return start
    }

    return nil
}

private func trackNameMeta(_ name: String) -> [UInt8] {
    [0xFF, 0x03, UInt8(name.utf8.count)] + Array(name.utf8)
}

// MARK: - Channel map

@Test func channelMapHandsOutMelodicChannelsInAscendingProgramOrderAndDrumsGetTen() {
    let programs = [0, 24, 40, NoteEvent.drumProgram]
    let counts = [0: 3, 24: 2, 40: 1, NoteEvent.drumProgram: 9]

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .reuseChannels)

    #expect(map == [0: 1, 24: 2, 40: 3, NoteEvent.drumProgram: 10])
}

@Test func channelMapReservesChannelTenEvenWithoutDrums() {
    let programs = Array(0..<10)
    let counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .reuseChannels)

    #expect(map[8] == 9)
    #expect(map[9] == 11)
    #expect(!map.values.contains(10))
}

@Test func channelMapReuseModeCyclesThroughTheLastSixChannelsFromIndexNine() {
    let programs = Array(0..<17)
    let counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .reuseChannels)

    // The 15 melodic channels, in order, for the first 15 programs.
    #expect((0..<15).map { map[$0] } == [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16])
    // The 16th and 17th wrap to index 9 of that list and on.
    #expect(map[15] == 11)
    #expect(map[16] == 12)
    #expect(map.count == 17)
}

@Test func channelMapReuseModeKeepsCyclingPastTheFirstWrap() {
    let programs = Array(0..<22)
    let counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .reuseChannels)

    #expect((15..<21).map { map[$0] } == [11, 12, 13, 14, 15, 16])
    // 22nd instrument: back to the start of the reused span.
    #expect(map[21] == 11)
}

@Test func channelMapDropModeKeepsTheFifteenWithMostNotes() {
    let programs = Array(0..<17)
    var counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })
    counts[15] = 50
    counts[16] = 40

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .dropExtraInstruments)

    #expect(map.count == 15)
    #expect(map[15] == 15)
    #expect(map[16] == 16)
    // Among the single-note ties the two highest programs lose out.
    #expect(map[13] == nil)
    #expect(map[14] == nil)
    #expect(map[0] == 1)
    #expect(map[12] == 14)
}

@Test func channelMapDropModeBreaksTiesByLowerProgram() {
    let programs = Array(0..<16)
    let counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .dropExtraInstruments)

    #expect(map.count == 15)
    #expect(map[15] == nil)
    #expect((0..<15).map { map[$0] } == [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16])
}

@Test func channelMapDropModeNeverDropsDrums() {
    let programs = Array(0..<17) + [NoteEvent.drumProgram]
    var counts = Dictionary(uniqueKeysWithValues: programs.map { ($0, 1) })
    counts[NoteEvent.drumProgram] = 1

    let map = MidiFileWriter.channelMap(
        programsAscending: programs, noteCounts: counts, mode: .dropExtraInstruments)

    #expect(map[NoteEvent.drumProgram] == 10)
    #expect(map.count == 16)
}

// MARK: - File bytes

@Test func singleNoteFileIsByteForByteWhatTheFormatAsksFor() {
    let data = MidiFileWriter.data(
        notes: [note(0.5, 1.0, pitch: 60, program: 0)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)

    let expected: [UInt8] = [
        // MThd, length 6, format 1, 2 tracks, 960 ticks per quarter note.
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x02, 0x03, 0xC0,
        // Conductor track: tempo (500000 µs/qn), 4/4, end of track.
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x13,
        0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
        0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,
        0x00, 0xFF, 0x2F, 0x00,
        // Piano track: name, program change, note on at tick 960, note off at tick 1920.
        0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x1A,
        0x00, 0xFF, 0x03, 0x05, 0x50, 0x69, 0x61, 0x6E, 0x6F,
        0x00, 0xC0, 0x00,
        0x87, 0x40, 0x90, 0x3C, 0x64,
        0x87, 0x40, 0x80, 0x3C, 0x00,
        0x00, 0xFF, 0x2F, 0x00,
    ]

    #expect([UInt8](data) == expected)
}

@Test func headerAnnouncesFormatOneAndNineSixtyTicks() {
    let data = MidiFileWriter.data(
        notes: [note(0.5, 1.0, pitch: 60, program: 0)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)

    let prefix: [UInt8] = [
        0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x02, 0x03, 0xC0,
    ]

    #expect(Array([UInt8](data).prefix(prefix.count)) == prefix)
    #expect(MidiFileWriter.ticksPerQuarterNote == 960)
}

@Test func conductorTrackCarriesTempoAndFourFourAtTickZero() {
    let data = MidiFileWriter.data(
        notes: [note(0.5, 1.0, pitch: 60, program: 0)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let parsed = chunks(data)

    #expect(parsed[0].type == "MThd")
    #expect(parsed[1].type == "MTrk")
    #expect(contains(parsed[1].body, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))
    #expect(contains(parsed[1].body, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))
    #expect(Array(parsed[1].body.suffix(4)) == [0x00, 0xFF, 0x2F, 0x00])
}

@Test func tempoMetaEventFollowsTheBpm() {
    let data = MidiFileWriter.data(
        notes: [note(0, 1, pitch: 60, program: 0)],
        bpm: 90, startOffsetSeconds: 0, mode: .reuseChannels)

    // 1e6 * 60 / 90 = 666666.67 µs per quarter note, rounded to 666667 = 0x0A2C2B.
    #expect(contains(chunks(data)[1].body, [0xFF, 0x51, 0x03, 0x0A, 0x2C, 0x2B]))
}

@Test func instrumentTrackStartsWithItsUiNameAndProgramChange() {
    let data = MidiFileWriter.data(
        notes: [note(0, 1, pitch: 60, program: 24)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let track = chunks(data)[2].body

    let name = Instruments.info(forProgram: 24).name
    #expect(Array(track.prefix(1 + trackNameMeta(name).count)) == [0x00] + trackNameMeta(name))
    #expect(contains(track, [0x00, 0xC0, 24]))
}

@Test func tracksComeInAscendingProgramOrderWithDrumsLast() {
    let notes = [
        note(0, 1, pitch: 38, program: NoteEvent.drumProgram),
        note(0, 1, pitch: 60, program: 40),
        note(0, 1, pitch: 60, program: 0),
    ]
    let data = MidiFileWriter.data(
        notes: notes, bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let parsed = chunks(data)

    #expect(parsed.count == 5)
    #expect(Array([UInt8](data)[10..<12]) == [0x00, 0x04])  // four tracks in the header
    let names = [0, 40, NoteEvent.drumProgram].map { Instruments.info(forProgram: $0).name }
    #expect(indexOf(parsed[2].body, trackNameMeta(names[0])) == 1)
    #expect(indexOf(parsed[3].body, trackNameMeta(names[1])) == 1)
    #expect(indexOf(parsed[4].body, trackNameMeta(names[2])) == 1)
}

@Test func drumTrackSitsOnChannelTenAndSelectsTheStandardKit() {
    let data = MidiFileWriter.data(
        notes: [note(0, 0.01, pitch: 38, program: NoteEvent.drumProgram)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let track = chunks(data)[2].body

    #expect(contains(track, trackNameMeta("Drums")))
    // Program change on channel 10 (0xC9) selecting program 0, not 128.
    #expect(contains(track, [0x00, 0xC9, 0x00]))
    #expect(contains(track, [0x99, 0x26, 0x64]))  // note on, channel 10
    #expect(contains(track, [0x89, 0x26, 0x00]))  // note off, channel 10
}

@Test func velocityIsAmplitudeScaledToSevenBits() {
    let data = MidiFileWriter.data(
        notes: [note(0, 1, pitch: 60, program: 0, amplitude: 0.5)],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)

    // round(0.5 * 127) = 64.
    #expect(contains(chunks(data)[2].body, [0x90, 0x3C, 0x40]))
}

@Test func velocityIsClampedIntoRange() {
    let data = MidiFileWriter.data(
        notes: [
            note(0, 1, pitch: 60, program: 0, amplitude: 2.0),
            note(0, 1, pitch: 62, program: 0, amplitude: -1.0),
        ],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let track = chunks(data)[2].body

    #expect(contains(track, [0x90, 0x3C, 0x7F]))
    #expect(contains(track, [0x90, 0x3E, 0x00]))
}

@Test func startOffsetShiftsEveryTick() {
    let data = MidiFileWriter.data(
        notes: [note(0, 0.5, pitch: 60, program: 0)],
        bpm: 120, startOffsetSeconds: 0.5, mode: .reuseChannels)
    let track = chunks(data)[2].body

    // (0 + 0.5) * 120 / 60 * 960 = 960, and (0.5 + 0.5) * ... = 1920.
    #expect(contains(track, [0x87, 0x40, 0x90, 0x3C, 0x64]))
    #expect(contains(track, [0x87, 0x40, 0x80, 0x3C, 0x00]))
}

@Test func gridExportOffsetPutsTheDownbeatOnAFileBarLine() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0.5, division: .quarter)
    let data = MidiFileWriter.data(
        notes: [note(grid.offsetSeconds, grid.offsetSeconds + 0.5, pitch: 60, program: 0)],
        bpm: grid.bpm, startOffsetSeconds: grid.exportStartOffsetSeconds, mode: .reuseChannels)
    let track = chunks(data)[2].body

    // The note on is the first event after the track name and the program change; its delta
    // time from tick 0 is the note's tick.
    let name = Instruments.info(forProgram: 0).name
    var i = 1 + trackNameMeta(name).count + 3
    var tick = 0
    while i < track.count {
        tick = tick << 7 | Int(track[i] & 0x7F)
        if track[i] & 0x80 == 0 { break }
        i += 1
    }
    #expect(Array(track[(i + 1)..<(i + 4)]) == [0x90, 0x3C, 0x64])
    #expect(tick > 0)
    #expect(tick % (MidiFileWriter.ticksPerQuarterNote * 4) == 0)
}

@Test func noteOffComesBeforeNoteOnAtTheSameTick() {
    let data = MidiFileWriter.data(
        notes: [
            note(0, 1, pitch: 60, program: 0),
            note(1, 2, pitch: 64, program: 0),
        ],
        bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let track = chunks(data)[2].body

    // At 120 bpm one second is 1920 ticks, so the first note ends exactly where the second starts.
    let expectedTail: [UInt8] = [
        0x00, 0x90, 0x3C, 0x64,  // note on pitch 60 at tick 0
        0x8F, 0x00, 0x80, 0x3C, 0x00,  // note off pitch 60 at tick 1920
        0x00, 0x90, 0x40, 0x64,  // note on pitch 64 at the same tick, after the note off
        0x8F, 0x00, 0x80, 0x40, 0x00,  // note off pitch 64 at tick 3840
        0x00, 0xFF, 0x2F, 0x00,
    ]
    #expect(Array(track.suffix(expectedTail.count)) == expectedTail)
}

@Test func droppedInstrumentsGetNoTrackAndNoNotes() {
    var notes: [NoteEvent] = []
    for program in 0..<17 {
        notes.append(note(0, 1, pitch: 60 + program, program: program))
    }
    notes.append(contentsOf: (0..<5).map { note(Double($0), Double($0) + 0.5, pitch: 70, program: 16) })

    let data = MidiFileWriter.data(
        notes: notes, bpm: 120, startOffsetSeconds: 0, mode: .dropExtraInstruments)
    let parsed = chunks(data)

    // Conductor + 15 instruments.
    #expect(parsed.count == 17)
    #expect(Array([UInt8](data)[10..<12]) == [0x00, 0x10])
    let kept = parsed.dropFirst(2).map { $0.body }
    func hasTrack(for program: Int) -> Bool {
        kept.contains { contains($0, trackNameMeta(Instruments.info(forProgram: program).name)) }
    }
    // Program 16 carries the most notes, so it survives; the highest-numbered ties go.
    #expect(hasTrack(for: 16))
    #expect(hasTrack(for: 0))
    #expect(!hasTrack(for: 14))
    #expect(!hasTrack(for: 15))
}

@Test func emptyTranscriptionStillWritesAConductorTrack() {
    let data = MidiFileWriter.data(
        notes: [], bpm: 120, startOffsetSeconds: 0, mode: .reuseChannels)
    let parsed = chunks(data)

    #expect(parsed.count == 2)
    #expect(Array([UInt8](data)[10..<12]) == [0x00, 0x01])
    #expect(contains(parsed[1].body, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))
}

@Test func nonPositiveBpmFallsBackRatherThanProducingGarbage() {
    let data = MidiFileWriter.data(
        notes: [note(0, 1, pitch: 60, program: 0)],
        bpm: 0, startOffsetSeconds: 0, mode: .reuseChannels)

    #expect(contains(chunks(data)[1].body, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))
}

// MARK: - Track specs

@Test func trackSpecCarriesTheFieldsATrackIsBuiltFrom() {
    let spec = MidiTrackSpec(program: 0, name: "Piano", channel: 1, notes: [note(0, 1, pitch: 60)])

    #expect(spec.program == 0)
    #expect(spec.name == "Piano")
    #expect(spec.channel == 1)
    #expect(spec.notes.count == 1)
}

// MARK: - Export file name

@Test func exportFileNameUsesTheSourceName() {
    #expect(
        MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: "song")
            == "song_NNTranscription.mid")
}

@Test func exportFileNameFallsBackWhenThereIsNoSource() {
    #expect(MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: nil) == "NNTranscription.mid")
    #expect(MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: "") == "NNTranscription.mid")
}
