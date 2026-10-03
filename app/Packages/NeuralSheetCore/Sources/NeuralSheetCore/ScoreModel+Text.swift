import Foundation

/// A section marker as the score prints it (markers and lyrics design §2): a boxed name over
/// the bar line nearest the marker, so the Score tab, the PDF and the MusicXML export agree on
/// the measure.
public struct ScoreRehearsal: Equatable, Sendable {
    /// 0-based, as `ScoreDocument.bars`.
    public var measure: Int
    public var text: String

    public init(measure: Int, text: String) {
        self.measure = measure
        self.text = text
    }
}

extension ScoreDocument {
    /// The markers on the measures: each at the bar line nearest it on the straight grid (a
    /// marker set by ear a hair before the downbeat still names the bar it means). One before the
    /// first bar line lands on the first measure; one nearest the score's final bar line, past
    /// every measure, is left out. Two landing on one measure share its mark, "Verse / Chorus",
    /// rather than one silently hiding the other. Unnamed markers print nothing.
    static func rehearsalMarks(_ markers: [Marker], bars: [ScoreBar], grid: TempoGrid) -> [ScoreRehearsal] {
        guard let last = bars.last else { return [] }

        var byMeasure: [Int: [String]] = [:]

        for marker in markers.sortedMarkers() {
            let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty else { continue }

            let units = Double(MusicXMLWriter.divisions) * grid.quarterBeats(atSeconds: marker.seconds)

            guard units.isFinite else { continue }

            // Bar lines are every bar's start and the last bar's end; the nearest wins, the
            // later on a tie (a marker halfway through a bar names the next section).
            var nearest = 0
            var distance = Double.infinity

            for index in 0...bars.count {
                let line = Double(index < bars.count ? bars[index].startUnits : last.endUnits)
                let gap = abs(line - units)

                if gap <= distance {
                    nearest = index
                    distance = gap
                }
            }

            guard nearest < bars.count else { continue }

            byMeasure[nearest, default: []].append(name)
        }

        return byMeasure.keys.sorted().map { ScoreRehearsal(measure: $0, text: byMeasure[$0]?.joined(separator: " / ") ?? "") }
    }
}
