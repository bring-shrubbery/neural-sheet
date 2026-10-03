import Foundation

/// The score's words (markers and lyrics design §2): a section marker as a `<rehearsal>`
/// direction on the first part written, and a note's syllable as a `<lyric>` with its
/// `<syllabic>` and, for a melisma, `<extend type="start"/>`.
extension MusicXMLWriter {
    /// The rehearsal mark of measure `measure`, or nothing. Written after the measure's
    /// attributes and before its tempo mark, so a reader meets the meter first and the mark
    /// stands over the bar line.
    static func rehearsalXML(_ marks: [ScoreRehearsal], measure: Int) -> String {
        guard let mark = marks.first(where: { $0.measure == measure }) else { return "" }

        return "      <direction placement=\"above\"><direction-type><rehearsal>\(escaped(mark.text))</rehearsal></direction-type></direction>\n"
    }

    /// One verse's `<lyric>` for `lyric`.
    static func lyricXML(_ lyric: Lyric) -> String {
        var xml = "<lyric number=\"1\"><syllabic>\(lyric.syllabic.rawValue)</syllabic><text>\(escaped(lyric.text))</text>"

        if lyric.extends { xml += "<extend type=\"start\"/>" }

        return xml + "</lyric>"
    }
}

extension ScorePiece {
    /// The index of the note that carries the piece's syllable: the highest that has one, so a
    /// chord prints one syllable, not one per head (markers and lyrics design §2). Nil for none.
    public var lyricNoteIndex: Int? {
        notes.lastIndex { $0.lyric != nil }
    }
}
