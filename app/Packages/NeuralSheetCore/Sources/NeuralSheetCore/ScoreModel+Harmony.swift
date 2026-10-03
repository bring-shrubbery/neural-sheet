import Foundation

/// One chord symbol of the score (chord symbols design §2): the measure it falls in, where in it,
/// and what it prints, so the Score tab and the MusicXML export place it alike.
public struct ScoreChord: Equatable, Sendable {
    /// 0-based, as `ScoreDocument.bars`.
    public var measure: Int
    /// Units from the measure's start.
    public var units: Int
    /// "B♭m7/F", or "N.C.".
    public var text: String
    /// Nil for N.C.
    public var chord: ChordSymbol?
    /// The event's index in the time-ordered list, so a click on the score finds it again.
    public var index: Int
    /// Whether the root and bass are spelled with flats: what the MusicXML's steps and alters say.
    public var flats: Bool

    public init(measure: Int, units: Int, text: String, chord: ChordSymbol?, index: Int = 0, flats: Bool) {
        self.measure = measure
        self.units = units
        self.text = text
        self.chord = chord
        self.index = index
        self.flats = flats
    }
}

extension ScoreDocument {
    /// The chord list on the measures: each event at its position on the straight grid, rounded to
    /// the nearest unit, spelled for `key` (concert pitch: the symbols name the sounding harmony).
    /// The chord already sounding when the first measure starts is written there; an event past
    /// the last measure is left out; of two at one place, the later, the one that sounds, is kept.
    static func scoreChords(_ chords: [ChordEvent], bars: [ScoreBar], grid: TempoGrid, key: MusicalKey?) -> [ScoreChord] {
        guard let first = bars.first, let last = bars.last else { return [] }

        var result: [ScoreChord] = []
        var measure = 0
        var sounding: (index: Int, event: ChordEvent)?

        for (index, event) in chords.sortedChords().enumerated() {
            let units = MusicXMLWriter.units(quarterBeats: grid.quarterBeats(atSeconds: event.seconds))

            guard units >= first.startUnits else {
                sounding = (index, event)
                continue
            }

            guard units < last.endUnits else { break }

            while measure + 1 < bars.count, bars[measure + 1].startUnits <= units { measure += 1 }

            let position = units - bars[measure].startUnits

            if let previous = result.last, previous.measure == measure, previous.units == position {
                result[result.count - 1] = scoreChord(event, index: index, measure: measure, units: position, key: key)
            } else {
                result.append(scoreChord(event, index: index, measure: measure, units: position, key: key))
            }
        }

        if let sounding, result.first.map({ $0.measure != 0 || $0.units != 0 }) ?? true {
            result.insert(scoreChord(sounding.event, index: sounding.index, measure: 0, units: 0, key: key), at: 0)
        }

        return result
    }

    private static func scoreChord(_ event: ChordEvent, index: Int, measure: Int, units: Int, key: MusicalKey?) -> ScoreChord {
        let flats = event.chord.map { ChordSymbol.prefersFlats(root: $0.root, minor: $0.quality.isMinor, key: key) } ?? false

        return ScoreChord(measure: measure, units: units, text: event.text(in: key), chord: event.chord, index: index, flats: flats)
    }
}

extension [ScoreChord] {
    /// The chord symbols in measure `measure`, in order.
    public func inMeasure(_ measure: Int) -> ArraySlice<ScoreChord> {
        guard let start = firstIndex(where: { $0.measure == measure }) else { return [] }

        let end = self[start...].firstIndex { $0.measure != measure } ?? endIndex

        return self[start..<end]
    }
}
