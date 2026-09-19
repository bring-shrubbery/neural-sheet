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

    public init(program: Int, name: String, channel: Int, notes: [NoteEvent]) {
        self.program = program
        self.name = name
        self.channel = channel
        self.notes = notes
    }
}

/// Writes a transcription out as a standard MIDI file, byte for byte what NeuralNote's JUCE-backed
/// writer produced: format 1, 960 ticks per quarter note, a conductor track and one track per
/// instrument.
///
/// One track per instrument (rather than one channel per instrument in a single track) is what
/// carries the instrument identity across reliably: many DAWs split an import by track and
/// re-channel it.
public enum MidiFileWriter {
    /// The file's time base. Every tick in the file is 1/960 of a quarter note at the export tempo.
    public static let ticksPerQuarterNote = 960

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

    /// The whole MIDI file as bytes, ready to be written to disk or handed to a drag.
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
                notes: notesByProgram[program] ?? [])
        }

        var bytes = header(trackCount: 1 + specs.count)
        bytes += conductorTrack(bpm: bpm)

        for spec in specs {
            bytes += instrumentTrack(spec, bpm: bpm, startOffsetSeconds: startOffsetSeconds)
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

    private static func conductorTrack(bpm: Double) -> [UInt8] {
        var body: [UInt8] = []

        let microsecondsPerQuarterNote = self.microsecondsPerQuarterNote(bpm: bpm)
        body += vlq(0)
        body += [
            0xFF, 0x51, 0x03,
            UInt8((microsecondsPerQuarterNote >> 16) & 0xFF),
            UInt8((microsecondsPerQuarterNote >> 8) & 0xFF),
            UInt8(microsecondsPerQuarterNote & 0xFF),
        ]

        // The model gives no meter, so 4/4 is a placeholder: 4 beats of a 2^2 note, 24 MIDI clocks
        // per metronome tick, 8 32nd notes per quarter note.
        body += vlq(0)
        body += [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]

        return chunk("MTrk", body + endOfTrack)
    }

    private static func instrumentTrack(
        _ spec: MidiTrackSpec, bpm: Double, startOffsetSeconds: Double
    ) -> [UInt8] {
        let channelBits = UInt8((min(max(spec.channel, 1), 16) - 1) & 0x0F)
        var body: [UInt8] = []

        // Track name (a type 3 text meta event) and the program change, both at tick 0.
        let nameBytes = Array(spec.name.utf8)
        body += vlq(0) + [0xFF, 0x03] + vlq(nameBytes.count) + nameBytes

        let program = spec.program == NoteEvent.drumProgram ? drumKitProgram : spec.program
        body += vlq(0) + [0xC0 | channelBits, UInt8(min(max(program, 0), 127))]

        // Sorting the notes first makes the file a function of the transcription rather than of the
        // order the notes happened to arrive in.
        struct Event {
            var tick: Int
            /// A note off sorts before a note on at the same tick, so a repeated pitch is released
            /// before it is struck again rather than being cut short by its own predecessor.
            var isNoteOn: Bool
            var bytes: [UInt8]
        }

        var events: [Event] = []
        events.reserveCapacity(spec.notes.count * 2)

        for note in spec.notes.sorted() {
            let pitch = UInt8(min(max(note.pitch, 0), 127))
            let velocity = UInt8(min(max(safeInt((note.amplitude * 127).rounded()), 0), 127))

            events.append(
                Event(
                    tick: tick(
                        seconds: note.startTime, bpm: bpm, startOffsetSeconds: startOffsetSeconds),
                    isNoteOn: true,
                    bytes: [0x90 | channelBits, pitch, velocity]))
            events.append(
                Event(
                    tick: tick(
                        seconds: note.endTime, bpm: bpm, startOffsetSeconds: startOffsetSeconds),
                    isNoteOn: false,
                    bytes: [0x80 | channelBits, pitch, 0x00]))
        }

        // A stable sort on (tick, note off first); `enumerated` keeps equal events in the order the
        // sorted notes produced them, since Swift's sort is not itself stable.
        let ordered = events.enumerated().sorted { lhs, rhs in
            (lhs.element.tick, lhs.element.isNoteOn ? 1 : 0, lhs.offset)
                < (rhs.element.tick, rhs.element.isNoteOn ? 1 : 0, rhs.offset)
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
    private static func vlq(_ value: Int) -> [UInt8] {
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
