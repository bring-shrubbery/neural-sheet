import Foundation

/// One instrument's MIDI track: what the writer needs to know about it once the channel map has
/// decided where it goes.
public struct MidiTrackSpec: Equatable, Sendable {
    /// The instrument, 0-127 or ``NoteEvent/drumProgram``.
    public var program: Int
    /// The UI instrument name, written as the track's name meta event.
    public var name: String
    /// The MIDI channel, 1-16 as the MIDI spec counts them (10 is the drum channel).
    public var channel: Int
    /// Every note of this instrument, in whatever order; the writer sorts them.
    public var notes: [NoteEvent]
    /// CC 10, 0…127 with 64 the centre (click design §2). Written after the program change only
    /// when it is not the centre, so a file from an unpanned mix is byte for byte what it was.
    public var pan: Int

    public init(program: Int, name: String, channel: Int, notes: [NoteEvent], pan: Int = MidiFileWriter.centrePan) {
        self.program = program
        self.name = name
        self.channel = channel
        self.notes = notes
        self.pan = pan
    }
}

/// Writes a transcription out as a standard MIDI file, byte for byte what NeuralNote's JUCE-backed
/// writer produced: format 1, 960 ticks per quarter note, a conductor track and one track per
/// instrument. Written from a tempo grid, the conductor track carries a tempo and a meter at each
/// of the map's changes and every tick goes through the map, so a DAW's bars are the score's
/// (tempo map design §2); one 4/4 segment gives the same bytes as the one-tempo writer.
///
/// One track per instrument (rather than one channel per instrument in a single track) is what
/// carries the instrument identity across reliably: many DAWs split an import by track and
/// re-channel it.
public enum MidiFileWriter {
    /// The file's time base. Every tick in the file is 1/960 of a quarter note at the export tempo.
    public static let ticksPerQuarterNote = 960

    /// CC 10's centre, which a track with no pan is left at by not writing the controller.
    public static let centrePan = 64

    /// The mixer's −1…1 pan as CC 10: `(pan + 1) × 63.5`, rounded and clamped (click design §2),
    /// so −1 is 0, 0 is 64 and 1 is 127.
    public static func midiPan(_ pan: Double) -> Int {
        let clamped = InstrumentMixerState.clampedPan(pan)

        return min(max(Int(((clamped + 1) * 63.5).rounded()), 0), 127)
    }

    // MARK: - Channels

    /// General MIDI percussion. A melodic instrument here plays as drums whatever its program
    /// change says, so it is never handed out to one, even when the transcription has no drums.
    private static let drumChannel = 10

    /// The 15 channels left for melodic instruments, in the order they are handed out.
    private static let melodicChannels = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16]

    /// Where `reuseChannels` starts handing channels out again: the block above the drums, so a
    /// reused channel is always one of the last few rather than colliding with the first
    /// instrument found.
    private static let reuseFirstIndex = 9

    /// Channel 10 selects its kit from the note number, so the program there names the kit rather
    /// than the instrument. 0 is the standard kit.
    private static let drumKitProgram = 0

    /// Assigns a MIDI channel to every instrument in the transcription.
    ///
    /// Melodic instruments take ``melodicChannels`` in ascending program order, which is the order
    /// the sidebar shows them in. Past the 15th, `mode` decides: `reuseChannels` cycles through the
    /// last six of the list, `dropExtraInstruments` keeps the 15 carrying the most notes (ties
    /// broken by the lower program) and leaves the rest out of the map entirely.
    ///
    /// - Parameters:
    ///   - programsAscending: the programs present in the transcription; sorted and de-duplicated
    ///     here as well, so a caller cannot get a different file out by passing them in some other
    ///     order.
    ///   - noteCounts: how many notes each program carries, read only by `dropExtraInstruments`.
    /// - Returns: program → channel (1-16), without the programs that were dropped.
    public static func channelMap(
        programsAscending: [Int], noteCounts: [Int: Int], mode: MidiOverflowMode
    ) -> [Int: Int] {
        let programs = Set(programsAscending).sorted()
        var melodic = programs.filter { $0 != NoteEvent.drumProgram }

        if mode == .dropExtraInstruments, melodic.count > melodicChannels.count {
            // Keep whatever carries the most notes: a lead is worth more than an incidental
            // instrument with three notes, whatever their program numbers say.
            let byNoteCount = melodic.sorted { lhs, rhs in
                let lhsCount = noteCounts[lhs] ?? 0
                let rhsCount = noteCounts[rhs] ?? 0

                return lhsCount != rhsCount ? lhsCount > rhsCount : lhs < rhs
            }
            melodic = byNoteCount.prefix(melodicChannels.count).sorted()
        }

        var map: [Int: Int] = [:]

        for (index, program) in melodic.enumerated() {
            if index < melodicChannels.count {
                map[program] = melodicChannels[index]
            } else {
                let reuseSpan = melodicChannels.count - reuseFirstIndex
                let overflowIndex = index - melodicChannels.count
                map[program] = melodicChannels[reuseFirstIndex + overflowIndex % reuseSpan]
            }
        }

        if programs.contains(NoteEvent.drumProgram) {
            map[NoteEvent.drumProgram] = drumChannel
        }

        return map
    }

    // MARK: - The file

    /// The whole MIDI file over `grid`'s tempo map: tick 0 is the bar line
    /// ``TempoGrid/exportStartOffsetSeconds`` before the audio, and each note's tick is its
    /// quarter beats from there × 960. Each of `markers` is a marker meta event in the conductor
    /// track at its own tick (markers and lyrics design §2), so a DAW shows the sections.
    ///
    /// `pans` is the mixer's pan by program (−1…1); a program not in it is centred.
    public static func data(notes: [NoteEvent], grid: TempoGrid, mode: MidiOverflowMode, markers: [Marker] = [],
                            pans: [Int: Double] = [:]) -> Data {
        let first = grid.segments[0]
        let fileStartSeconds = -grid.exportStartOffsetSeconds
        // Whole bars of the first segment from tick 0 to bar 1, so tick 0 is a bar line exactly.
        let barsBefore = first.barSeconds > 0 ? ((grid.offsetSeconds - fileStartSeconds) / first.barSeconds).rounded() : 0
        let fileStartBeats = -barsBefore * first.timeSignature.quarterBeatsPerBar

        // Where each segment starts, in seconds and in quarter beats from tick 0. The first is
        // anchored at tick 0 itself, so a one-segment grid computes `(seconds + offset) × bpm / 60`
        // exactly as the one-tempo writer does and gives its bytes.
        let anchors = [(seconds: fileStartSeconds, beats: 0.0, bpm: first.bpm)]
            + grid.segments.dropFirst().map { segment in
                (seconds: grid.barStart(bar: segment.startBar),
                 beats: grid.quarterBeats(atBar: segment.startBar) - fileStartBeats,
                 bpm: segment.bpm)
            }

        func ticks(beats: Double) -> Int {
            max(0, safeInt((beats * Double(ticksPerQuarterNote)).rounded()))
        }

        var meta: [(tick: Int, bytes: [UInt8])] = []
        var meter: TimeSignature?

        for (segment, anchor) in zip(grid.segments, anchors) {
            let tick = ticks(beats: anchor.beats)
            meta.append((tick, tempoEvent(bpm: segment.bpm)))

            if segment.timeSignature != meter {
                meta.append((tick, timeSignatureEvent(segment.timeSignature)))
                meter = segment.timeSignature
            }
        }

        func tick(_ seconds: Double) -> Int {
            let anchor = anchors.last { $0.seconds <= seconds } ?? anchors[0]

            return ticks(beats: anchor.beats + (seconds - anchor.seconds) * anchor.bpm / 60.0)
        }

        return data(notes: notes, mode: mode, conductor: withMarkers(meta, markers, tick: tick), pans: pans, tick: tick)
    }

    /// The whole MIDI file at one tempo in 4/4, ready to be written to disk or handed to a drag.
    ///
    /// - Parameters:
    ///   - bpm: the export tempo, which sets both the tempo meta event and the seconds-to-ticks
    ///     conversion. A non-positive or non-finite value falls back to 120 rather than producing
    ///     an unreadable file.
    ///   - startOffsetSeconds: added to every note time, so MIDI time 0 can be made to land on a
    ///     bar line for a take recorded against a rolling transport.
    public static func data(
        notes: [NoteEvent], bpm: Double, startOffsetSeconds: Double, mode: MidiOverflowMode
    ) -> Data {
        // The model gives no meter, so 4/4 is a placeholder.
        let conductor = [(tick: 0, bytes: tempoEvent(bpm: bpm)), (tick: 0, bytes: timeSignatureEvent(.common))]

        return data(notes: notes, mode: mode, conductor: conductor, pans: [:]) { seconds in
            tick(seconds: seconds, bpm: bpm, startOffsetSeconds: startOffsetSeconds)
        }
    }

    /// The file from its conductor track's meta events (in tick order) and a note's tick.
    private static func data(
        notes: [NoteEvent], mode: MidiOverflowMode, conductor: [(tick: Int, bytes: [UInt8])],
        pans: [Int: Double], tick: (Double) -> Int
    ) -> Data {
        var noteCounts: [Int: Int] = [:]
        var notesByProgram: [Int: [NoteEvent]] = [:]

        for note in notes {
            noteCounts[note.program, default: 0] += 1
            notesByProgram[note.program, default: []].append(note)
        }

        let map = channelMap(
            programsAscending: noteCounts.keys.sorted(), noteCounts: noteCounts, mode: mode)

        // Ascending program order, matching the sidebar; drums (program 128) therefore come last.
        let specs = map.keys.sorted().map { program in
            MidiTrackSpec(
                program: program,
                name: Instruments.info(forProgram: program).name,
                channel: map[program] ?? 1,
                notes: notesByProgram[program] ?? [],
                pan: pans[program].map(midiPan) ?? centrePan)
        }

        var bytes = header(trackCount: 1 + specs.count)
        bytes += conductorTrack(conductor)

        for spec in specs {
            bytes += instrumentTrack(spec, tick: tick)
        }

        return Data(bytes)
    }

    /// The name both MIDI exits give the file, e.g. `"song_NNTranscription.mid"`. A recorded take
    /// has no source file to be named after and falls back to `"NNTranscription.mid"`.
    public static func exportFileName(sourceFileNameWithoutExtension: String?) -> String {
        guard let name = sourceFileNameWithoutExtension, !name.isEmpty else {
            return "NNTranscription.mid"
        }

        return "\(name)_NNTranscription.mid"
    }

    // MARK: - Chunks

    private static func header(trackCount: Int) -> [UInt8] {
        // Format 1: a conductor track plus tracks meant to be played together.
        let body =
            bigEndian16(1) + bigEndian16(trackCount) + bigEndian16(ticksPerQuarterNote)

        return chunk("MThd", body)
    }

    /// The meta events, each at its tick's delta from the last.
    private static func conductorTrack(_ events: [(tick: Int, bytes: [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        var lastTick = 0

        for event in events {
            body += vlq(max(0, event.tick - lastTick)) + event.bytes
            lastTick = max(lastTick, event.tick)
        }

        return chunk("MTrk", body + endOfTrack)
    }

    /// `FF 51`: microseconds per quarter note.
    private static func tempoEvent(bpm: Double) -> [UInt8] {
        let microsecondsPerQuarterNote = self.microsecondsPerQuarterNote(bpm: bpm)

        return [
            0xFF, 0x51, 0x03,
            UInt8((microsecondsPerQuarterNote >> 16) & 0xFF),
            UInt8((microsecondsPerQuarterNote >> 8) & 0xFF),
            UInt8(microsecondsPerQuarterNote & 0xFF),
        ]
    }

    /// `FF 58`: the numerator, the denominator as a power of two, MIDI clocks per metronome click
    /// (24 a quarter; a dotted beat in a compound meter) and 8 32nd notes per quarter note.
    private static func timeSignatureEvent(_ meter: TimeSignature) -> [UInt8] {
        let power = UInt8(meter.denominator.trailingZeroBitCount)
        let clocks = 96 / meter.denominator * (meter.isCompound ? 3 : 1)

        return [0xFF, 0x58, 0x04, UInt8(meter.numerator), power, UInt8(min(max(clocks, 1), 255)), 0x08]
    }

    private static func instrumentTrack(_ spec: MidiTrackSpec, tick: (Double) -> Int) -> [UInt8] {
        let channelBits = UInt8((min(max(spec.channel, 1), 16) - 1) & 0x0F)
        var body: [UInt8] = []

        // Track name (a type 3 text meta event) and the program change, both at tick 0.
        let nameBytes = Array(spec.name.utf8)
        body += vlq(0) + [0xFF, 0x03] + vlq(nameBytes.count) + nameBytes

        let program = spec.program == NoteEvent.drumProgram ? drumKitProgram : spec.program
        body += vlq(0) + [0xC0 | channelBits, UInt8(min(max(program, 0), 127))]

        // CC 10 at tick 0, after the program change (click design §2); a centred track has none,
        // which every player reads as the centre anyway.
        if spec.pan != centrePan {
            body += vlq(0) + [0xB0 | channelBits, 10, UInt8(min(max(spec.pan, 0), 127))]
        }

        // Sorting the notes first makes the file a function of the transcription rather than of the
        // order the notes happened to arrive in.
        let sorted = spec.notes.sorted()

        // A monophonic line with pitch curves opens with the bend range and carries its bends
        // (`MidiFileWriter+Bend.swift`); any other track is unchanged.
        let bends = bends(for: sorted, channelBits: channelBits, tick: tick)
        body += bends.setup

        // A note off sorts before a note on at the same tick, so a repeated pitch is released
        // before it is struck again rather than being cut short by its own predecessor. Each
        // syllable is a lyric meta event just before its note's strike (`+Text`).
        var events = bends.events + lyricEvents(for: sorted, tick: tick)
        events.reserveCapacity(events.count + sorted.count * 2)

        for note in sorted {
            let pitch = UInt8(min(max(note.pitch, 0), 127))
            let velocity = UInt8(min(max(safeInt((note.amplitude * 127).rounded()), 0), 127))

            events.append(
                TrackEvent(
                    tick: tick(note.startTime),
                    order: TrackEvent.noteOn,
                    bytes: [0x90 | channelBits, pitch, velocity]))
            events.append(
                TrackEvent(
                    tick: tick(note.endTime),
                    order: TrackEvent.noteOff,
                    bytes: [0x80 | channelBits, pitch, 0x00]))
        }

        // A stable sort on (tick, order); `enumerated` keeps equal events in the order they were
        // produced, since Swift's sort is not itself stable.
        let ordered = events.enumerated().sorted { lhs, rhs in
            (lhs.element.tick, lhs.element.order, lhs.offset)
                < (rhs.element.tick, rhs.element.order, rhs.offset)
        }

        var lastTick = 0

        for (_, event) in ordered {
            body += vlq(max(0, event.tick - lastTick))
            // Running status is deliberately not used: a full status byte on every event costs a
            // byte and reads the same to every parser.
            body += event.bytes
            lastTick = event.tick
        }

        return chunk("MTrk", body + endOfTrack)
    }

    /// Delta 0, then the end-of-track meta event every `MTrk` chunk has to finish with.
    private static let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

    // MARK: - Encoding helpers

    /// A chunk: its four-character type, its length as a big-endian 32-bit count, then its body.
    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count)
        let lengthBytes = [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ]

        return Array(type.utf8) + lengthBytes + body
    }

    /// A MIDI variable-length quantity: seven bits per byte, high bit set on every byte but the
    /// last.
    static func vlq(_ value: Int) -> [UInt8] {
        var remaining = UInt32(max(0, value))
        var bytes: [UInt8] = [UInt8(remaining & 0x7F)]
        remaining >>= 7

        while remaining > 0 {
            bytes.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
            remaining >>= 7
        }

        return bytes
    }

    private static func bigEndian16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    // MARK: - Time

    private static func tick(seconds: Double, bpm: Double, startOffsetSeconds: Double) -> Int {
        let beats = (seconds + startOffsetSeconds) * safeBpm(bpm) / 60.0

        return max(0, safeInt((beats * Double(ticksPerQuarterNote)).rounded()))
    }

    private static func microsecondsPerQuarterNote(bpm: Double) -> Int {
        // Microseconds per beat: 1e6 seconds/second ÷ beats per second.
        let micros = (1.0e6 * 60.0 / safeBpm(bpm)).rounded()

        // The tempo meta event carries three bytes and nothing else fits.
        return min(max(safeInt(micros), 1), 0xFF_FFFF)
    }

    /// The export tempo, or the 120 default for a value that would make the arithmetic meaningless.
    private static func safeBpm(_ bpm: Double) -> Double {
        bpm.isFinite && bpm > 0 ? bpm : 120.0
    }

    /// `Int(_:)` traps on an infinite or NaN double, which a bad tempo or note time could otherwise
    /// reach; anything out of range is clamped instead.
    private static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }

        return Int(min(max(value, -1.0e15), 1.0e15))
    }
}
