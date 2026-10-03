import Foundation

/// One measure's place in time (tempo map design §2): where it starts and how long it is, in
/// units of ``MusicXMLWriter/divisions`` per quarter from the grid's downbeat, the meter and tempo
/// in force, and whether the score marks them there. Every bar length in units is whole, since a
/// bar of `n/d` is `n × 96/d` units and `d` is at most 32, so bar lines never fall between units.
public struct ScoreBar: Equatable, Sendable {
    public var startUnits: Int
    public var lengthUnits: Int
    public var timeSignature: TimeSignature
    public var bpm: Double
    /// The first measure, and wherever the meter changes.
    public var showsTimeSignature: Bool
    /// The first measure, and wherever the tempo changes.
    public var showsTempo: Bool

    public var endUnits: Int { startUnits + lengthUnits }

    /// The bars of `span` (0-based indices from the downbeat, so index 0 is the grid's bar 1).
    static func table(_ span: Range<Int>, grid: TempoGrid) -> [ScoreBar] {
        var result: [ScoreBar] = []
        result.reserveCapacity(span.count)

        for index in span {
            let segment = grid.segment(atBar: index + 1)
            let previous = result.last

            result.append(ScoreBar(startUnits: MusicXMLWriter.units(quarterBeats: grid.quarterBeats(atBar: index + 1)),
                                   lengthUnits: MusicXMLWriter.units(quarterBeats: segment.timeSignature.quarterBeatsPerBar),
                                   timeSignature: segment.timeSignature,
                                   bpm: segment.bpm,
                                   showsTimeSignature: previous?.timeSignature != segment.timeSignature,
                                   showsTempo: previous?.bpm != segment.bpm))
        }

        return result
    }
}

extension ScoreDocument {
    // MARK: - Time

    /// The measure (0-based) and the position in it, in units, at `seconds`; nil before the first
    /// measure or past the last. Through the tempo map, so the Score tab's playhead follows a
    /// tempo change.
    public func measureIndex(atSeconds seconds: Double, grid: TempoGrid) -> (measure: Int, units: Double)? {
        let units = grid.quarterBeats(atSeconds: seconds) * Double(MusicXMLWriter.divisions)

        guard let first = bars.first, let last = bars.last,
              units >= Double(first.startUnits), units < Double(last.endUnits) else { return nil }

        var low = 0
        var high = bars.count - 1

        while low < high {
            let middle = (low + high + 1) / 2
            if Double(bars[middle].startUnits) <= units { low = middle } else { high = middle - 1 }
        }

        return (low, units - Double(bars[low].startUnits))
    }

    /// The seconds at `units` into measure `measure` (0-based), never before 0.
    public func seconds(atMeasure measure: Int, units: Double, grid: TempoGrid) -> Double {
        let start = bars.indices.contains(measure)
            ? Double(bars[measure].startUnits)
            : grid.quarterBeats(atBar: firstBar + measure + 1) * Double(MusicXMLWriter.divisions)

        return max(0, grid.seconds(atQuarterBeats: (start + units) / Double(MusicXMLWriter.divisions)))
    }
}
