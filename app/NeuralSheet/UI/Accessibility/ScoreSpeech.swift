import Foundation
import NeuralSheetCore

/// A note, chord or rest of the score as VoiceOver reads it (a11y design §2): "E4 G4, dotted
/// quarter note, Piano, bar 5". Apart from the views, so the Mac's score and the iPhone and iPad
/// score read the same words.
enum ScoreSpeech {
    /// "E4 G4, dotted quarter note, Piano, bar 5", or "quarter rest, Piano, bar 5".
    static func description(of piece: ScorePiece, part: String, bar: Int) -> String {
        let value = noteValue(piece)

        if piece.isRest {
            return String(localized: "\(value) rest, \(part), bar \(bar)",
                          comment: "VoiceOver: a rest in the score, e.g. \"quarter rest, Piano, bar 5\"; the first value is a note value such as \"quarter\"")
        }

        let pitches = piece.notes.map { TimeFormat.pitchName($0.pitch) }.joined(separator: " ")

        return String(localized: "\(pitches), \(value) note, \(part), bar \(bar)",
                      comment: "VoiceOver: a note or chord in the score, e.g. \"E4 G4, quarter note, Piano, bar 5\"; the second value is a note value such as \"quarter\"")
    }

    /// "quarter", "dotted eighth": the value as a musician names it.
    static func noteValue(_ piece: ScorePiece) -> String {
        let name: String =
            switch piece.type {
            case "whole": String(localized: "whole", comment: "VoiceOver: a note value, as in \"whole note\"")
            case "half": String(localized: "half", comment: "VoiceOver: a note value, as in \"half note\"")
            case "quarter": String(localized: "quarter", comment: "VoiceOver: a note value, as in \"quarter note\"")
            case "eighth": String(localized: "eighth", comment: "VoiceOver: a note value, as in \"eighth note\"")
            case "16th": String(localized: "sixteenth", comment: "VoiceOver: a note value, as in \"sixteenth note\"")
            case "32nd": String(localized: "thirty-second", comment: "VoiceOver: a note value, as in \"thirty-second note\"")
            default: piece.type
            }

        guard piece.dots > 0 else { return name }

        return String(localized: "dotted \(name)", comment: "VoiceOver: a dotted note value, e.g. \"dotted quarter\"")
    }
}
