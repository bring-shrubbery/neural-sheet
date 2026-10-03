import Foundation
import Testing

@testable import NeuralSheetCore

// The MIDI reader (MIDI import design §3).

// MARK: - Building files by hand

private func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func header(format: Int, tracks: Int, division: Int) -> [UInt8] {
    Array("MThd".utf8) + be32(6) + [0, UInt8(format), 0, UInt8(tracks), UInt8(division >> 8), UInt8(division & 0xFF)]
}

private func track(_ body: [UInt8], length: Int? = nil) -> [UInt8] {
    Array("MTrk".utf8) + be32(length ?? body.count) + body
}

private let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

/// 120 BPM is 500 000 µs a quarter; 60 BPM is 1 000 000.
private func tempo(_ micros: Int) -> [UInt8] {
    [0xFF, 0x51, 0x03, UInt8(micros >> 16), UInt8((micros >> 8) & 0xFF), UInt8(micros & 0xFF)]
}

private func close(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - Round trip

/// A small deterministic generator, so a failure names a seed that reproduces it.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Notes on a 10 ms lattice (so no two distinct times share a tick at any tempo here), at least
/// 50 ms long, with drums, repeated and overlapping pitches, and up to 20 instruments so the
/// overflow modes have work to do.
private func randomNotes(_ rng: inout SplitMix) -> [NoteEvent] {
    let instrumentCount = Int.random(in: 1...20, using: &rng)
    var programs = (0..<instrumentCount).map { _ in Int.random(in: 0...127, using: &rng) }
    if Bool.random(using: &rng) { programs.append(NoteEvent.drumProgram) }

    return (0..<Int.random(in: 1...60, using: &rng)).map { _ in
        let start = Double(Int.random(in: 0...2000, using: &rng)) / 100
        let length = Double(Int.random(in: 5...200, using: &rng)) / 100

        return NoteEvent(startTime: start, endTime: start + length, pitch: Int.random(in: 40...52, using: &rng),
                         amplitude: NoteEvent.amplitude(forVelocity: Int.random(in: 1...127, using: &rng)),
                         program: programs.randomElement(using: &rng) ?? 0)
    }
}

/// What a file written from `notes` should read back as: the instruments the channel map kept,
/// with overlapping same-pitch notes merged (a note-off cannot say which of two open notes it
/// ends, so only their union is defined).
private func expected(_ notes: [NoteEvent], mode: MidiOverflowMode) -> [NoteEvent] {
    var counts: [Int: Int] = [:]
    for note in notes { counts[note.program, default: 0] += 1 }
    let kept = MidiFileWriter.channelMap(programsAscending: Array(counts.keys), noteCounts: counts, mode: mode)

    return mergeOverlappingNotesWithSamePitch(notes.filter { kept[$0.program] != nil })
}

private func roundTrip(grid: TempoGrid, seeds: Range<UInt64>) throws {
    // One tick at the slowest tempo in the map.
    let tick = 60 / (grid.segments.map(\.bpm).min() ?? 120) / Double(MidiFileWriter.ticksPerQuarterNote)

    for mode in [MidiOverflowMode.reuseChannels, .dropExtraInstruments] {
        for seed in seeds {
            var rng = SplitMix(state: seed)
            let notes = randomNotes(&rng)
            let file = try MidiFileReader.read(MidiFileWriter.data(notes: notes, grid: grid, mode: mode))
            let shift = grid.exportStartOffsetSeconds
            let read = mergeOverlappingNotesWithSamePitch(file.allNotes.map {
                NoteEvent(startTime: $0.startTime - shift, endTime: $0.endTime - shift, pitch: $0.pitch,
                          amplitude: $0.amplitude, program: $0.program)
            })
            let want = expected(notes, mode: mode)

            try #require(read.count == want.count, "seed \(seed) \(mode)")

            for (got, note) in zip(read, want) {
                #expect(got.pitch == note.pitch && got.program == note.program && got.velocity == note.velocity,
                        "seed \(seed) \(mode)")
                #expect(close(got.startTime, note.startTime, tick * 1.001) && close(got.endTime, note.endTime, tick * 1.001),
                        "seed \(seed) \(mode): \(got) vs \(note)")
                #expect(got.confidence == nil)
            }
        }
    }
}

@Test func whatTheWriterWritesReadsBackAtOneTempo() throws {
    try roundTrip(grid: TempoGrid(bpm: 97), seeds: 0..<100)
}

@Test func whatTheWriterWritesReadsBackOverATempoMap() throws {
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120),
                                    GridSegment(startBar: 3, bpm: 75, timeSignature: TimeSignature(numerator: 3, denominator: 4)),
                                    GridSegment(startBar: 6, bpm: 140, timeSignature: TimeSignature(numerator: 7, denominator: 8))])
    try roundTrip(grid: grid, seeds: 100..<200)
}

@Test func whatTheWriterWritesReadsBackWithADownbeatOffset() throws {
    try roundTrip(grid: TempoGrid(bpm: 110, offsetSeconds: 0.37), seeds: 200..<220)
}

@Test func theWritersMapAndTrackNamesComeBack() throws {
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120),
                                    GridSegment(startBar: 5, bpm: 90, timeSignature: TimeSignature(numerator: 3, denominator: 4))])
    let notes = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0),
                 NoteEvent(startTime: 0, endTime: 1, pitch: 36, program: NoteEvent.drumProgram),
                 NoteEvent(startTime: 9, endTime: 10, pitch: 64, program: 40)]
    let file = try MidiFileReader.read(MidiFileWriter.data(notes: notes, grid: grid, mode: .reuseChannels))

    #expect(file.format == 1)
    #expect(file.ticksPerQuarter == 960)
    #expect(file.tempoMap.map(\.tick) == [0, 4 * 4 * 960])
    #expect(file.firstBpm == 120)
    #expect(file.firstTimeSignature == .common)
    #expect(file.gridSegments() == grid.segments)
    #expect(file.tracks.map(\.name) == [nil] + [0, 40, NoteEvent.drumProgram].map { Instruments.info(forProgram: $0).name })
    #expect(file.allNotes.map(\.program) == [0, NoteEvent.drumProgram, 40])
    #expect(close(file.allNotes[2].startTime, 9, 1e-6), "the note after the change lands at the right second")
}

// MARK: - Hand-built files

@Test func aTypeZeroFileWithRunningStatusATempoChangeAndAProgramChange() throws {
    let body: [UInt8] = [0x00] + tempo(500_000)
        + [0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]      // 3/4
        + [0x00, 0xC2, 0x18]                                       // channel 3: program 24
        + [0x00, 0x92, 60, 100]                                    // C4 on at 0
        + [0x83, 0x60, 60, 0]                                      // running status, velocity 0: off at 480
        + [0x00, 0xFF, 0x7F, 0x02, 0xAA, 0xBB]                     // a sequencer meta, skipped
        + [0x00, 0xF0, 0x02, 0x7E, 0xF7]                           // sysex, skipped
        + [0x00, 0xB2, 0x07, 0x64]                                 // a controller, skipped
        + [0x00] + tempo(1_000_000)                                // 60 BPM from tick 480
        + [0x00, 0x92, 62, 50]                                     // D4 on at 480
        + [0x83, 0x60, 0x82, 62, 0]                                // a real note-off at 960
        + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body)))

    #expect(file.format == 0)
    #expect(file.tempoMap == [MidiTempoEvent(tick: 0, microsecondsPerQuarter: 500_000),
                              MidiTempoEvent(tick: 480, microsecondsPerQuarter: 1_000_000)])
    #expect(file.firstTimeSignature == TimeSignature(numerator: 3, denominator: 4))
    #expect(file.allNotes.count == 2)
    #expect(file.allNotes[0] == NoteEvent(startTime: 0, endTime: 0.5, pitch: 60,
                                          amplitude: NoteEvent.amplitude(forVelocity: 100), program: 24))
    #expect(file.allNotes[1] == NoteEvent(startTime: 0.5, endTime: 1.5, pitch: 62,
                                          amplitude: NoteEvent.amplitude(forVelocity: 50), program: 24))
    #expect(file.gridSegments() == [GridSegment(startBar: 1, bpm: 60, timeSignature: TimeSignature(numerator: 3, denominator: 4))],
            "a change a third of a bar in rounds to bar 1, and the later tempo wins")
}

@Test func aTempoChangeOnALaterBarBecomesASegment() throws {
    // 4/4 at 480 ppq: bar 3 starts at tick 3840; a change at 3900 is nearest bar 3.
    let body: [UInt8] = [0x00] + tempo(500_000) + [0x9E, 0x3C] + tempo(750_000) + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body)))

    #expect(file.tempoMap.map(\.tick) == [0, 3900])
    #expect(file.gridSegments() == [GridSegment(startBar: 1, bpm: 120), GridSegment(startBar: 3, bpm: 80)])
}

@Test func aFileWithoutTempoIs120AndLeavesTheGridAlone() throws {
    let body: [UInt8] = [0x00, 0x90, 60, 64, 0x87, 0x40, 0x80, 60, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 960) + track(body)))

    #expect(file.firstBpm == nil)
    #expect(file.gridSegments() == nil)
    #expect(file.allNotes.map(\.endTime) == [0.5], "960 ticks at 120 BPM is half a second")
}

@Test func tempoInALaterTrackOfATypeOneFileStillCounts() throws {
    let conductor = endOfTrack
    let notes: [UInt8] = [0x00] + tempo(1_000_000) + [0x00, 0x90, 60, 64, 0x83, 0x60, 0x80, 60, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 1, tracks: 2, division: 480) + track(conductor) + track(notes)))

    #expect(file.allNotes.map(\.endTime) == [1])
}

@Test func aProgramSetInTheConductorTrackReachesTheNotesOnItsChannel() throws {
    let conductor: [UInt8] = [0x00, 0xC1, 33] + endOfTrack
    let notes: [UInt8] = [0x00, 0x91, 40, 64, 0x60, 0x81, 40, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 1, tracks: 2, division: 480) + track(conductor) + track(notes)))

    #expect(file.allNotes.map(\.program) == [33])
}

@Test func channelTenIsDrumsWhateverItsProgram() throws {
    let body: [UInt8] = [0x00, 0xC9, 0x10, 0x00, 0x99, 36, 90, 0x60, 0x89, 36, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body)))

    #expect(file.allNotes.map(\.program) == [NoteEvent.drumProgram])
}

@Test func sameNoteOverlapsCloseFirstInFirstOut() throws {
    // C4 on at 0, on again at 240, off at 480, off at 720.
    let body: [UInt8] = [0x00, 0x90, 60, 100, 0x81, 0x70, 0x90, 60, 50, 0x81, 0x70, 0x80, 60, 0, 0x81, 0x70, 0x80, 60, 0]
        + endOfTrack
    let notes = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body))).allNotes

    #expect(notes.map(\.startTime) == [0, 0.25])
    #expect(notes.map(\.endTime) == [0.5, 0.75])
    #expect(notes.map(\.velocity) == [100, 50])
}

@Test func notesStillOpenCloseAtTheEndOfTheTrack() throws {
    let body: [UInt8] = [0x00, 0x90, 60, 100, 0x00, 0x90, 64, 100, 0x83, 0x60, 0x80, 64, 0, 0x87, 0x40, 0xFF, 0x2F, 0x00]
    let notes = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body))).allNotes

    #expect(notes.map(\.pitch) == [60, 64])
    #expect(notes.map(\.endTime) == [1.5, 0.5], "the open C closes at the end-of-track tick, 1440")
}

@Test func aZeroLengthNoteIsDropped() throws {
    let body: [UInt8] = [0x00, 0x90, 60, 100, 0x00, 0x80, 60, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body)))

    #expect(file.allNotes.isEmpty)
}

@Test func aSmpteDivisionCountsFramesNotBeats() throws {
    // 25 fps, 40 ticks a frame: 1000 ticks a second, whatever the tempo says.
    let division = Int(UInt8(bitPattern: -25)) << 8 | 40
    let body: [UInt8] = [0x00] + tempo(1_000_000) + [0x00, 0x90, 60, 100, 0x87, 0x68, 0x80, 60, 0] + endOfTrack
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: division) + track(body)))

    #expect(file.ticksPerQuarter == nil)
    #expect(file.smpte == MidiSmpteDivision(framesPerSecond: 25, ticksPerFrame: 40))
    #expect(file.allNotes.map(\.endTime) == [1])
    #expect(file.gridSegments() == nil)
}

// MARK: - Malformed files

@Test func malformedFilesThrow() throws {
    let good = header(format: 0, tracks: 1, division: 480) + track([0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0] + endOfTrack)

    #expect(throws: MidiFileReader.Error.notMidi) { try MidiFileReader.read(Data("RIFF....".utf8)) }
    #expect(throws: MidiFileReader.Error.notMidi) { try MidiFileReader.read(Data()) }
    #expect(throws: MidiFileReader.Error.unsupportedFormat(2)) {
        try MidiFileReader.read(Data(header(format: 2, tracks: 1, division: 480) + track(endOfTrack)))
    }
    #expect(throws: MidiFileReader.Error.notMidi) {
        try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 0) + track(endOfTrack)))
    }

    for cut in [10, 16, 20, good.count - 1] {
        #expect(throws: MidiFileReader.Error.truncated, "cut at \(cut)") { try MidiFileReader.read(Data(good.prefix(cut))) }
    }

    #expect(throws: MidiFileReader.Error.truncated, "a second track the header promised") {
        try MidiFileReader.read(Data(header(format: 1, tracks: 2, division: 480) + track(endOfTrack)))
    }

    let body: [UInt8] = [0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0] + endOfTrack
    #expect(throws: MidiFileReader.Error.badTrackLength, "a length that ends mid-event") {
        try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body, length: 6) + endOfTrack))
    }
    #expect(throws: MidiFileReader.Error.badTrackLength, "a length that ends before the end-of-track event") {
        try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body, length: 8) + endOfTrack))
    }
    #expect(throws: MidiFileReader.Error.truncated, "a data byte with no status") {
        try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track([0x00, 60, 100] + endOfTrack)))
    }
    #expect(throws: MidiFileReader.Error.truncated, "an undefined status byte") {
        try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track([0x00, 0xF4] + endOfTrack)))
    }
}

@Test func paddingAfterTheEndOfTrackEventIsIgnored() throws {
    let body: [UInt8] = [0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0] + endOfTrack + [0, 0, 0]
    let file = try MidiFileReader.read(Data(header(format: 0, tracks: 1, division: 480) + track(body)))

    #expect(file.allNotes.count == 1)
}
