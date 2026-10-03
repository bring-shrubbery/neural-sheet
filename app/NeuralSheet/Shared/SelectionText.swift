import Foundation
import NeuralSheetCore

/// What the selection's fields say (design §6.3), shared by the Mac's inspector and note card and
/// the iPhone and iPad's note card, so both read a selection the same way: the count, the
/// read-only confidence and pitch-curve rows, and the pitch field's parsing.
nonisolated enum SelectionText {
    static func count(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No selection", comment: "The selection panel and the note card: nothing selected")
        default: String(localized: "\(count) notes", comment: "The selection panel and the note card: how many notes are selected")
        }
    }

    /// "72 %", "31 – 88 %" for a selection that disagrees, "—" when no selected note came from the
    /// model. A drawn note in a mixed selection counts as sure, as it does everywhere confidence
    /// is read.
    static func confidence(_ notes: [NoteEvent]) -> String {
        guard notes.contains(where: { $0.confidence != nil }) else { return "—" }

        let percents = notes.map { Int(($0.confidenceOrSure * 100).rounded()) }
        let lowest = percents.min() ?? 0
        let highest = percents.max() ?? 0

        return lowest == highest ? "\(lowest) %" : "\(lowest) – \(highest) %"
    }

    /// "±N ¢", the largest deviation in any selected note's curve, or "—" when none has one.
    static func pitchCurve(_ notes: [NoteEvent]) -> String {
        let curves = notes.compactMap(\.pitchCurve).filter { !$0.isEmpty }

        guard !curves.isEmpty else { return "—" }

        let largest = curves.map { $0.map(abs).max() ?? 0 }.max() ?? 0

        return "±\(Int(largest.rounded())) ¢"
    }

    /// A note name or a MIDI number as the pitch field takes it: `C4`, `C#4`, `Db-1`, or `60`.
    static func parsePitch(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()

        if let number = Int(trimmed) { return (0...127).contains(number) ? number : nil }

        let names: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

        guard let letter = trimmed.first, var pitchClass = names[letter] else { return nil }

        var rest = trimmed.dropFirst()

        if rest.first == "#" { pitchClass += 1; rest = rest.dropFirst() }
        else if rest.first == "B", rest.count > 1 { pitchClass -= 1; rest = rest.dropFirst() }

        guard let octave = Int(rest) else { return nil }

        let midi = (octave + 1) * 12 + pitchClass

        return (0...127).contains(midi) ? midi : nil
    }
}
