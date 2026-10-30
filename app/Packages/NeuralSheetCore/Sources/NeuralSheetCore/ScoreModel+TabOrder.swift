import Foundation

/// One tab note in a part's reading order, with the measure it starts in.
public struct ScoreTabStop: Equatable, Sendable {
    public var id: NoteID
    /// 0-based, as `ScoreDocument.bars`.
    public var measure: Int

    public init(id: NoteID, measure: Int) {
        self.id = id
        self.measure = measure
    }
}

extension ScoreDocument {
    /// A part's tab notes as ← / → step through them (arrangement design §4): measure by
    /// measure, piece by piece, a chord's notes lowest pitch first, so the order holds while
    /// their strings change. A note tied over a bar line is one stop, where it starts. Empty
    /// when the part has no tab or is not in the score.
    public func tabStops(program: Int) -> [ScoreTabStop] {
        guard let tab = parts.first(where: { $0.program == program })?.tab else { return [] }

        var stops: [ScoreTabStop] = []
        var seen: Set<NoteID> = []

        for (index, measure) in tab.measures.enumerated() {
            for piece in measure.pieces {
                for note in piece.notes.sorted(by: { $0.pitch < $1.pitch }) {
                    guard let id = note.id, seen.insert(id).inserted else { continue }

                    stops.append(ScoreTabStop(id: id, measure: index))
                }
            }
        }

        return stops
    }
}
