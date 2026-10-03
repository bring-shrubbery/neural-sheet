import Foundation

/// A tempo change in a MIDI file: from `tick` on, a quarter note lasts this many microseconds.
public struct MidiTempoEvent: Equatable, Sendable {
    public var tick: Int
    public var microsecondsPerQuarter: Int

    public init(tick: Int, microsecondsPerQuarter: Int) {
        self.tick = tick
        self.microsecondsPerQuarter = microsecondsPerQuarter
    }

    public var bpm: Double { 60_000_000 / Double(microsecondsPerQuarter) }
}

/// A meter change in a MIDI file.
public struct MidiTimeSignatureEvent: Equatable, Sendable {
    public var tick: Int
    public var timeSignature: TimeSignature

    public init(tick: Int, timeSignature: TimeSignature) {
        self.tick = tick
        self.timeSignature = timeSignature
    }
}

/// A SMPTE time division: ticks are fractions of a video frame, and the tempo map does not
/// move them.
public struct MidiSmpteDivision: Equatable, Sendable {
    /// 24, 25, 29.97 or 30.
    public var framesPerSecond: Double
    public var ticksPerFrame: Int
}

/// One `MTrk` chunk's name and notes, in seconds.
public struct MidiTrack: Equatable, Sendable {
    public var name: String?
    public var notes: [NoteEvent]

    public init(name: String?, notes: [NoteEvent]) {
        self.name = name
        self.notes = notes
    }
}

/// What a Standard MIDI File holds that NeuralSheet can use (MIDI import design §2–§3): notes
/// in seconds, and the tempo map and meters in ticks for the grid. Callers never convert ticks
/// to seconds themselves.
public struct MidiFile: Equatable, Sendable {
    public var format: Int
    /// The time base of a metrical file; nil for a SMPTE one.
    public var ticksPerQuarter: Int?
    public var smpte: MidiSmpteDivision?
    /// Every tempo event of every track, merged by tick (one per tick, the last given).
    public var tempoMap: [MidiTempoEvent]
    public var timeSignatures: [MidiTimeSignatureEvent]
    public var tracks: [MidiTrack]
    /// Every track's notes, sorted.
    public var allNotes: [NoteEvent]

    /// The tempo the file starts at, if it gives one (a file without is 120 BPM by the spec).
    public var firstBpm: Double? { tempoMap.first?.bpm }

    public var firstTimeSignature: TimeSignature? { timeSignatures.first?.timeSignature }
}

/// Reads a Standard MIDI File, formats 0 and 1: the inverse of ``MidiFileWriter`` (MIDI import
/// design §3). Defensive by construction: every read is bounds-checked, and any malformation
/// throws, so a caller gets the whole file's notes or none.
public enum MidiFileReader {
    public enum Error: Swift.Error, Equatable {
        /// No `MThd` header, or a time division of zero.
        case notMidi
        /// Format 2 (independent sequences) or a format number the spec does not define.
        case unsupportedFormat(Int)
        /// The file ends before its header or its tracks do, or holds a byte no event starts with.
        case truncated
        /// A track's events run past its declared length, or the length ends before the
        /// end-of-track event.
        case badTrackLength
    }

    public static func read(url: URL) throws -> MidiFile {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> MidiFile {
        let bytes = [UInt8](data)
        var cursor = ByteCursor(bytes)

        guard bytes.count >= 4, Array(bytes[0..<4]) == Array("MThd".utf8) else { throw Error.notMidi }

        try cursor.skip(4)
        let headerLength = try cursor.u32()
        guard headerLength >= 6 else { throw Error.notMidi }

        let format = try cursor.u16()
        let trackCount = try cursor.u16()
        let division = try cursor.u16()
        try cursor.skip(headerLength - 6)

        guard format == 0 || format == 1 else { throw Error.unsupportedFormat(format) }

        let clock = try Division(division)
        var raw: [MidiRawTrack] = []

        while raw.count < trackCount {
            let type = Array(try cursor.bytes(4))
            let length = try cursor.u32()
            let start = cursor.position

            // The file was cut short if a chunk claims more than is left.
            try cursor.skip(length)

            // Chunks of other types are allowed by the spec and skipped.
            if type == Array("MTrk".utf8) {
                raw.append(try parseTrack(bytes, from: start, to: start + length))
            }
        }

        return assemble(format: format, clock: clock, raw: raw)
    }

    // MARK: - Time

    /// The header's division word: ticks per quarter note, or (high bit set) SMPTE frames per
    /// second as a negative byte and ticks per frame.
    enum Division {
        case metrical(ticksPerQuarter: Int)
        case smpte(MidiSmpteDivision)

        init(_ word: Int) throws {
            if word & 0x8000 == 0 {
                guard word > 0 else { throw Error.notMidi }

                self = .metrical(ticksPerQuarter: word)
            } else {
                let frames = -Int(Int8(bitPattern: UInt8(word >> 8)))
                let ticksPerFrame = word & 0xFF
                guard frames > 0, ticksPerFrame > 0 else { throw Error.notMidi }

                // 29 is drop-frame NTSC, 29.97 frames a second.
                let fps = frames == 29 ? 29.97 : Double(frames)
                self = .smpte(MidiSmpteDivision(framesPerSecond: fps, ticksPerFrame: ticksPerFrame))
            }
        }
    }

    /// Ticks to seconds over the merged tempo map: a prefix sum of each tempo span's seconds, so
    /// a tick is one binary search and one multiply away (MIDI import design §3).
    struct TempoClock {
        private var ticks: [Int] = [0]
        private var seconds: [Double] = [0]
        private var secondsPerTick: [Double]

        init(division: Division, tempoMap: [MidiTempoEvent]) {
            switch division {
            case .smpte(let smpte):
                secondsPerTick = [1 / (smpte.framesPerSecond * Double(smpte.ticksPerFrame))]

            case .metrical(let ppq):
                // No tempo event at tick 0 is 120 BPM until the first one.
                secondsPerTick = [0.5 / Double(ppq)]

                for event in tempoMap {
                    let rate = Double(event.microsecondsPerQuarter) / 1_000_000 / Double(ppq)

                    if event.tick == ticks[ticks.count - 1] {
                        secondsPerTick[secondsPerTick.count - 1] = rate
                    } else {
                        seconds.append(self.seconds(atTick: event.tick))
                        ticks.append(event.tick)
                        secondsPerTick.append(rate)
                    }
                }
            }
        }

        func seconds(atTick tick: Int) -> Double {
            var low = 0
            var high = ticks.count - 1

            while low < high {
                let middle = (low + high + 1) / 2
                if ticks[middle] <= tick { low = middle } else { high = middle - 1 }
            }

            return seconds[low] + Double(tick - ticks[low]) * secondsPerTick[low]
        }
    }

    // MARK: - Notes

    private static func assemble(format: Int, clock division: Division, raw: [MidiRawTrack]) -> MidiFile {
        // Tempo and meter events from every track, merged by tick: the spec puts them in the
        // first track, DAWs do not always (MIDI import design §2). The sort is stable on track
        // order, and the last event at a tick wins.
        var tempos: [MidiTempoEvent] = []
        var meters: [MidiTimeSignatureEvent] = []

        for track in raw {
            for (tick, event) in track.events {
                switch event {
                case .tempo(let micros): tempos.append(MidiTempoEvent(tick: tick, microsecondsPerQuarter: micros))
                case .timeSignature(let meter): meters.append(MidiTimeSignatureEvent(tick: tick, timeSignature: meter))
                default: break
                }
            }
        }

        let tempoMap = lastPerTick(tempos, tick: \.tick)
        let clock = TempoClock(division: division, tempoMap: tempoMap)
        let programs = ProgramTimeline(raw)
        let tracks = raw.enumerated().map { index, track in
            MidiTrack(name: trackName(track), notes: notes(of: track, index: index, clock: clock, programs: programs))
        }

        var ticksPerQuarter: Int?
        var smpte: MidiSmpteDivision?

        switch division {
        case .metrical(let ppq): ticksPerQuarter = ppq
        case .smpte(let value): smpte = value
        }

        return MidiFile(format: format, ticksPerQuarter: ticksPerQuarter, smpte: smpte, tempoMap: tempoMap,
                        timeSignatures: lastPerTick(meters, tick: \.tick), tracks: tracks,
                        allNotes: tracks.flatMap(\.notes).sorted())
    }

    private static func lastPerTick<Event>(_ events: [Event], tick: KeyPath<Event, Int>) -> [Event] {
        let ordered = events.enumerated().sorted { ($0.element[keyPath: tick], $0.offset) < ($1.element[keyPath: tick], $1.offset) }
        var result: [Event] = []

        for (_, event) in ordered {
            if let last = result.last, last[keyPath: tick] == event[keyPath: tick] {
                result[result.count - 1] = event
            } else {
                result.append(event)
            }
        }

        return result
    }

    private static func trackName(_ track: MidiRawTrack) -> String? {
        for (_, event) in track.events {
            if case .trackName(let name) = event { return name }
        }

        return nil
    }

    /// The track's notes. A note-off (or a velocity-0 note-on) closes the earliest open note of
    /// its channel and pitch, first in first out, which is what overlapping notes written by
    /// ``MidiFileWriter`` mean; notes still open at the end of the track close there. A note
    /// with no length can be neither drawn nor heard and is dropped (MIDI import design §2).
    private static func notes(of track: MidiRawTrack, index: Int, clock: TempoClock,
                              programs: ProgramTimeline) -> [NoteEvent] {
        struct Key: Hashable { var channel: Int, pitch: Int }
        struct Open { var tick: Int, velocity: Int }

        var open: [Key: [Open]] = [:]
        var notes: [NoteEvent] = []

        func close(_ key: Key, _ start: Open, at tick: Int) {
            let startSeconds = clock.seconds(atTick: start.tick)
            let endSeconds = clock.seconds(atTick: tick)

            guard endSeconds > startSeconds, (0...127).contains(key.pitch) else { return }

            // Channel 10 is General MIDI percussion whatever program it was given.
            let program = key.channel == 9 ? NoteEvent.drumProgram
                : programs.program(track: index, channel: key.channel, atTick: start.tick)
            notes.append(NoteEvent(startTime: startSeconds, endTime: endSeconds, pitch: key.pitch,
                                   amplitude: NoteEvent.amplitude(forVelocity: start.velocity), program: program))
        }

        for (tick, event) in track.events {
            switch event {
            case .noteOn(let channel, let pitch, let velocity):
                open[Key(channel: channel, pitch: pitch), default: []].append(Open(tick: tick, velocity: velocity))

            case .noteOff(let channel, let pitch):
                let key = Key(channel: channel, pitch: pitch)

                if var queue = open[key], !queue.isEmpty {
                    close(key, queue.removeFirst(), at: tick)
                    open[key] = queue
                }

            default:
                break
            }
        }

        let endTick = max(track.endTick, track.events.last?.tick ?? 0)

        for (key, queue) in open {
            for start in queue { close(key, start, at: endTick) }
        }

        return notes.sorted()
    }
}

/// Which program each channel plays at a tick (MIDI import design §2): the last program change
/// at or before it in the note's own track, else in any track (a type-1 file may set programs
/// from its first track), else 0.
struct ProgramTimeline {
    private struct Key: Hashable { var track: Int?, channel: Int }

    private var changes: [Key: [(tick: Int, program: Int)]] = [:]

    init(_ tracks: [MidiRawTrack]) {
        var global: [Int: [(order: Int, tick: Int, program: Int)]] = [:]
        var order = 0

        for (index, track) in tracks.enumerated() {
            for (tick, event) in track.events {
                guard case .program(let channel, let program) = event else { continue }

                changes[Key(track: index, channel: channel), default: []].append((tick, program))
                global[channel, default: []].append((order, tick, program))
                order += 1
            }
        }

        for (channel, list) in global {
            changes[Key(track: nil, channel: channel)] = list.sorted { ($0.tick, $0.order) < ($1.tick, $1.order) }
                .map { ($0.tick, $0.program) }
        }
    }

    func program(track: Int, channel: Int, atTick tick: Int) -> Int {
        Self.last(in: changes[Key(track: track, channel: channel)], atOrBefore: tick)
            ?? Self.last(in: changes[Key(track: nil, channel: channel)], atOrBefore: tick)
            ?? 0
    }

    private static func last(in list: [(tick: Int, program: Int)]?, atOrBefore tick: Int) -> Int? {
        list?.last { $0.tick <= tick }?.program
    }
}
