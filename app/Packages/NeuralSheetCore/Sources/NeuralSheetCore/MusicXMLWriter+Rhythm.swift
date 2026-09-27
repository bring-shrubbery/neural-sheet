import Foundation

/// The rhythm side of the score (MusicXML design §2): seconds to grid units, the boundaries a
/// single voice can hold, and the printable values a stretch of units splits into.
extension MusicXMLWriter {
    /// A note in units of ``divisions`` per quarter from the grid's downbeat, half-open. Units
    /// before the downbeat are negative.
    struct UnitNote: Equatable {
        var start: Int
        var end: Int
        var pitch: Int
        var id: NoteID? = nil
    }

    /// The quantization step for a grid division, in units; a triplet division is straightened
    /// to the plain value of its size, since the score has no tuplets (§1).
    static func quantum(for division: GridDivision) -> Int {
        switch division {
        case .bar: barUnits
        case .half: divisions * 2
        case .quarter: divisions
        case .eighth, .eighthTriplet: divisions / 2
        case .sixteenth, .sixteenthTriplet: divisions / 4
        case .thirtySecond: divisions / 8
        }
    }

    /// Every note as units, start and end each to the nearest multiple of `quantum`, at least
    /// one quantum long; sorted by start then pitch.
    static func unitNotes(_ notes: [NoteEvent], grid: TempoGrid, quantum: Int) -> [UnitNote] {
        unitNotes(notes, ids: nil, grid: grid, quantum: quantum)
    }

    /// ``unitNotes(_:grid:quantum:)`` with the document's ids alongside, where there are any.
    static func unitNotes(_ notes: [NoteEvent], ids: [NoteID?]?, grid: TempoGrid, quantum: Int) -> [UnitNote] {
        let unitsPerSecond = Double(divisions) / grid.secondsPerBeat
        let step = max(1, quantum)

        func units(_ seconds: Double) -> Int {
            let raw = (seconds - grid.offsetSeconds) * unitsPerSecond
            guard raw.isFinite else { return 0 }
            return Int((raw / Double(step)).rounded()) * step
        }

        return notes.enumerated().map { index, note in
            let start = units(note.startTime)
            let end = max(units(note.endTime), start + step)
            let id = ids.flatMap { index < $0.count ? $0[index] : nil }

            return UnitNote(start: start, end: end, pitch: note.pitch, id: id)
        }
        .sorted { ($0.start, $0.pitch, $0.end) < ($1.start, $1.pitch, $1.end) }
    }

    /// A stretch over which the sounding notes do not change: one chord, or a rest when there
    /// are none. Never crosses a bar line.
    struct Segment: Equatable {
        var start: Int
        var end: Int
        /// Sounding across the whole segment, ascending pitch.
        var notes: [UnitNote]

        var isRest: Bool { notes.isEmpty }
    }

    /// The segments of `[from, to)`: every note start, note end and bar line inside it is a
    /// boundary, and each gap between consecutive boundaries is one segment.
    static func segments(_ notes: [UnitNote], from: Int, to: Int, barLength: Int = MusicXMLWriter.barUnits) -> [Segment] {
        guard to > from else { return [] }

        var boundaries: Set<Int> = [from, to]

        for note in notes {
            if note.start > from, note.start < to { boundaries.insert(note.start) }
            if note.end > from, note.end < to { boundaries.insert(note.end) }
        }

        if barLength > 0 {
            var bar = Int((Double(from) / Double(barLength)).rounded(.down)) * barLength
            while bar < to {
                if bar > from { boundaries.insert(bar) }
                bar += barLength
            }
        }

        let sorted = boundaries.sorted()
        var result: [Segment] = []
        result.reserveCapacity(sorted.count)

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            let sounding = notes.filter { $0.start <= start && $0.end >= end }
                .sorted { ($0.pitch, $0.start) < ($1.pitch, $1.start) }

            result.append(Segment(start: start, end: end, notes: sounding))
        }

        return result
    }

    /// One printable note value.
    struct Duration: Equatable {
        var units: Int
        var type: String
        var dots: Int
    }

    /// The values a score can print, longest first, as multiples of a 32nd.
    static let printable: [Duration] = [
        Duration(units: 96, type: "whole", dots: 0),
        Duration(units: 72, type: "half", dots: 1),
        Duration(units: 48, type: "half", dots: 0),
        Duration(units: 36, type: "quarter", dots: 1),
        Duration(units: 24, type: "quarter", dots: 0),
        Duration(units: 18, type: "eighth", dots: 1),
        Duration(units: 12, type: "eighth", dots: 0),
        Duration(units: 9, type: "16th", dots: 1),
        Duration(units: 6, type: "16th", dots: 0),
        Duration(units: 3, type: "32nd", dots: 0),
    ]

    /// `units` as a run of printable values, longest first, tied together by the caller. Units
    /// that are not a multiple of a 32nd are rounded up to one, so nothing is lost; under a 32nd
    /// is nothing.
    static func printableDurations(_ units: Int) -> [Duration] {
        let smallest = printable.last?.units ?? 3
        var remaining = Int((Double(units) / Double(smallest)).rounded(.up)) * smallest
        var result: [Duration] = []

        while remaining >= smallest {
            guard let value = printable.first(where: { $0.units <= remaining }) else { break }
            result.append(value)
            remaining -= value.units
        }

        return result
    }
}
