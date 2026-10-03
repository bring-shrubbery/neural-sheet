import Foundation

/// The part display's words (arrangement design §6), shared by the Mac's part card and the
/// iPhone and iPad's part sheet, so both offer the same transpositions under the same names.
nonisolated enum PartDisplayText {
    /// Written = sounding + semitones. Computed, so the names are in the language in effect.
    static var transpositionPresets: [(String, Int)] {
        [
            (String(localized: "None", comment: "Part card: no transposition"), 0),
            ("B♭ (+2)", 2),
            (String(localized: "B♭ tenor (+14)", comment: "Part card: a transposition, as a tenor saxophone reads"), 14),
            (String(localized: "E♭ alto (+9)", comment: "Part card: a transposition, as an alto saxophone reads"), 9),
            (String(localized: "E♭ baritone (+21)", comment: "Part card: a transposition, as a baritone saxophone reads"), 21),
            ("F (+7)", 7),
            ("A (+3)", 3),
            (String(localized: "Octave up (+12)", comment: "Part card: written an octave above the sound"), 12),
            (String(localized: "Octave down (−12)", comment: "Part card: written an octave below the sound"), -12),
        ]
    }

    static var custom: String { String(localized: "Custom", comment: "Part card: a transposition or tuning that is none of the presets") }
    static var none: String { String(localized: "None", comment: "Part card: no tab") }
    static var hidden: String { String(localized: "Hidden", comment: "Part card: the part is left off the score") }
    static var shown: String { String(localized: "Shown", comment: "Part card: the part is on the score") }
}
