import Foundation

/// Bounds-checked big-endian reads over a byte range (MIDI import design §3). Every read past
/// the end throws `overrun`, which is `truncated` for the file's chunk headers and
/// `badTrackLength` inside a track, where running off the end means the declared length and the
/// events disagree.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var position: Int
    let end: Int
    let overrun: MidiFileReader.Error

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil, overrun: MidiFileReader.Error = .truncated) {
        self.bytes = bytes
        self.position = start
        self.end = min(end ?? bytes.count, bytes.count)
        self.overrun = overrun
    }

    var isAtEnd: Bool { position >= end }
    var remaining: Int { max(0, end - position) }

    mutating func u8() throws -> UInt8 {
        guard position < end else { throw overrun }

        defer { position += 1 }

        return bytes[position]
    }

    func peek() throws -> UInt8 {
        guard position < end else { throw overrun }

        return bytes[position]
    }

    mutating func u16() throws -> Int { try Int(u8()) << 8 | Int(u8()) }

    mutating func u24() throws -> Int { try u16() << 8 | Int(u8()) }

    mutating func u32() throws -> Int { try u16() << 16 | u16() }

    /// A variable-length quantity: seven bits a byte, the high bit set on all but the last. The
    /// spec allows four bytes; a fifth continuation byte is garbage, not a bigger number.
    mutating func vlq() throws -> Int {
        var value = 0

        for _ in 0..<4 {
            let byte = try u8()
            value = value << 7 | Int(byte & 0x7F)

            if byte & 0x80 == 0 { return value }
        }

        throw overrun
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw overrun }

        defer { position += count }

        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws {
        _ = try bytes(count)
    }
}

/// One event of a track the reader keeps, at its absolute tick. Everything else (controllers,
/// bends, aftertouch, sysex, other meta events) is read past by its length (MIDI import design
/// §2).
enum MidiRawEvent: Equatable {
    case noteOn(channel: Int, pitch: Int, velocity: Int)
    case noteOff(channel: Int, pitch: Int)
    case program(channel: Int, program: Int)
    case tempo(microsecondsPerQuarter: Int)
    case timeSignature(TimeSignature)
    case trackName(String)
}

/// A track's kept events in file order, ticks non-decreasing, and the tick its end-of-track
/// event sits at, where notes still sounding are closed.
struct MidiRawTrack {
    var events: [(tick: Int, event: MidiRawEvent)] = []
    var endTick = 0
}

extension MidiFileReader {
    /// Walks one `MTrk` body. Running status is honoured for channel messages; a data byte with
    /// no status before it, or a status byte the file format does not define (`F1`–`F6`,
    /// `F8`–`FE`), throws rather than guessing how long it is. A body that ends without its
    /// end-of-track event has a length that disagrees with its events: `badTrackLength`.
    static func parseTrack(_ bytes: [UInt8], from start: Int, to end: Int) throws -> MidiRawTrack {
        var cursor = ByteCursor(bytes, from: start, to: end, overrun: .badTrackLength)
        var track = MidiRawTrack()
        var tick = 0
        var runningStatus: UInt8?

        while true {
            tick += try cursor.vlq()

            var status = try cursor.peek()

            if status < 0x80 {
                guard let running = runningStatus else { throw Error.truncated }

                status = running
            } else {
                _ = try cursor.u8()
            }

            switch status {
            case 0xFF:
                let type = try cursor.u8()
                let payload = try cursor.bytes(cursor.vlq())

                if type == 0x2F {
                    track.endTick = tick
                    // Anything after the end-of-track event, up to the declared length, is padding.
                    return track
                }

                if let event = metaEvent(type: type, payload: Array(payload)) {
                    track.events.append((tick, event))
                }

            case 0xF0, 0xF7:
                // Sysex and its escape: a length, then that many bytes.
                try cursor.skip(cursor.vlq())

            case 0x80...0xEF:
                runningStatus = status

                if let event = try channelEvent(status: status, cursor: &cursor) {
                    track.events.append((tick, event))
                }

            default:
                throw Error.truncated
            }
        }
    }

    /// The meta events the reader keeps: tempo (`51`), time signature (`58`), track name (`03`).
    private static func metaEvent(type: UInt8, payload: [UInt8]) -> MidiRawEvent? {
        switch type {
        case 0x51 where payload.count >= 3:
            let micros = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])

            return micros > 0 ? .tempo(microsecondsPerQuarter: micros) : nil

        case 0x58 where payload.count >= 2:
            // The denominator is a power of two; anything past 2⁵ is clamped by `TimeSignature`.
            let power = min(Int(payload[1]), 6)

            return .timeSignature(TimeSignature(numerator: Int(payload[0]), denominator: 1 << power))

        case 0x03:
            return .trackName(String(decoding: payload, as: UTF8.self))

        default:
            return nil
        }
    }

    /// A channel message's data bytes, read whatever the message; only notes and program changes
    /// are returned. A note-on at velocity 0 is a note-off, as the spec says.
    private static func channelEvent(status: UInt8, cursor: inout ByteCursor) throws -> MidiRawEvent? {
        let channel = Int(status & 0x0F)
        let first = Int(try cursor.u8() & 0x7F)

        switch status & 0xF0 {
        case 0xC0:
            return .program(channel: channel, program: first)

        case 0xD0:
            return nil

        case 0x80:
            _ = try cursor.u8()

            return .noteOff(channel: channel, pitch: first)

        case 0x90:
            let velocity = Int(try cursor.u8() & 0x7F)

            return velocity == 0 ? .noteOff(channel: channel, pitch: first)
                : .noteOn(channel: channel, pitch: first, velocity: velocity)

        default:
            // A0 aftertouch, B0 controller, E0 pitch bend: two data bytes, not read (out of scope).
            _ = try cursor.u8()

            return nil
        }
    }
}
