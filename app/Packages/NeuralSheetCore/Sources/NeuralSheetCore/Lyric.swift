import Foundation

/// One syllable of the words under a note (markers and lyrics design §2): the text, where it
/// sits in its word, and whether the voice holds it over the notes after (a melisma). One verse
/// only; verses are a non-goal.
public struct Lyric: Equatable, Hashable, Codable, Sendable {
    /// Where a syllable sits in its word. The raw values are MusicXML's `<syllabic>` words, and
    /// stable: the project stores them.
    public enum Syllabic: String, Codable, Sendable, CaseIterable {
        case single, begin, middle, end

        /// Whether another syllable of the same word follows: what draws the hyphen after it.
        public var continues: Bool { self == .begin || self == .middle }
    }

    public var text: String
    public var syllabic: Syllabic
    /// The syllable is held over the following notes: the score draws an extender line, MusicXML
    /// writes `<extend type="start"/>`.
    public var extends: Bool

    public init(text: String, syllabic: Syllabic = .single, extends: Bool = false) {
        self.text = text
        self.syllabic = syllabic
        self.extends = extends
    }

    // MARK: - Typed form

    /// The lyric as the entry card shows it: the text, then "-" when the word continues, then
    /// "_" for a melisma. What ``typed(_:after:)`` reads back.
    public var typed: String {
        text + (syllabic.continues ? "-" : "") + (extends ? "_" : "")
    }

    /// The text as karaoke players want it in a MIDI lyric event: a trailing "-" on a syllable
    /// whose word continues, so the player joins it to the next (markers and lyrics design §2).
    public var midiText: String {
        text + (syllabic.continues ? "-" : "")
    }

    /// What the user typed in the entry card, read as a lyric (markers and lyrics design §2,
    /// Lyric entry): a trailing "-" continues the word (begin, or middle when `previous` already
    /// continued one), no mark ends it (single, or end after a continuing syllable), and a
    /// trailing "_" is no mark plus a melisma. Nil for nothing but marks and spaces, which clears
    /// the note's lyric.
    public static func typed(_ input: String, after previous: Lyric?) -> Lyric? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var hyphen = false
        var extends = false

        while let last = text.last, last == "-" || last == "_" {
            if last == "-" { hyphen = true } else { extends = true }
            text.removeLast()
        }

        text = text.trimmingCharacters(in: .whitespaces)

        guard !text.isEmpty else { return nil }

        let continuing = previous?.syllabic.continues ?? false
        let syllabic: Syllabic = hyphen ? (continuing ? .middle : .begin) : (continuing ? .end : .single)

        return Lyric(text: text, syllabic: syllabic, extends: extends)
    }
}

/// Text from the clipboard cut into syllables (markers and lyrics design §2, Paste Lyrics):
/// words on whitespace, each word's syllables on "-", with begin / middle / end inside a word and
/// single for a word of one piece; a trailing "_" on a syllable makes it a melisma.
public enum LyricSplitter {
    public static func syllables(from text: String) -> [Lyric] {
        var result: [Lyric] = []

        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let pieces = word.split(separator: "-", omittingEmptySubsequences: true).compactMap { piece -> (String, Bool)? in
                var text = String(piece)
                var extends = false

                while text.hasSuffix("_") {
                    extends = true
                    text.removeLast()
                }

                return text.isEmpty ? nil : (text, extends)
            }

            for (index, piece) in pieces.enumerated() {
                let syllabic: Lyric.Syllabic =
                    pieces.count == 1 ? .single : index == 0 ? .begin : index == pieces.count - 1 ? .end : .middle
                result.append(Lyric(text: piece.0, syllabic: syllabic, extends: piece.1))
            }
        }

        return result
    }
}
