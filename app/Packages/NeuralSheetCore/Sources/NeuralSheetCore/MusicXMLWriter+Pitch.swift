import Foundation

/// The pitch side of the score (MusicXML design §2): spelling, the drums' staff positions, and
/// which clef or clefs a part gets.
extension MusicXMLWriter {
    struct Spelling: Equatable {
        var step: String
        /// −1 flat, 0, 1 sharp.
        var alter: Int
        var octave: Int
    }

    private static let sharpSteps: [(String, Int)] = [
        ("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0), ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0),
    ]
    private static let flatSteps: [(String, Int)] = [
        ("C", 0), ("D", -1), ("D", 0), ("E", -1), ("E", 0), ("F", 0), ("G", -1), ("G", 0), ("A", -1), ("A", 0), ("B", -1), ("B", 0),
    ]

    /// A MIDI pitch as step, alteration and octave, middle C being C4; the black keys in
    /// sharps or in flats.
    static func spelling(midi: Int, preferFlats: Bool) -> Spelling {
        let clamped = min(max(midi, 0), 127)
        let (step, alter) = (preferFlats ? flatSteps : sharpSteps)[clamped % 12]

        return Spelling(step: step, alter: alter, octave: clamped / 12 - 1)
    }

    /// Where a General MIDI drum note sits on the five-line percussion staff, and its head.
    static func drumDisplay(note: Int) -> (step: String, octave: Int, notehead: String?) {
        switch note {
        case 35, 36: ("F", 4, nil)                 // kick
        case 38, 40: ("C", 5, nil)                 // snare
        case 37: ("C", 5, "x")                     // side stick
        case 39: ("C", 5, "x")                     // clap
        case 41: ("G", 4, nil)                     // low floor tom
        case 43: ("A", 4, nil)                     // high floor tom
        case 45: ("D", 5, nil)                     // low tom
        case 47, 48: ("E", 5, nil)                 // mid toms
        case 50: ("F", 5, nil)                     // high tom
        case 42: ("G", 5, "x")                     // closed hi-hat
        case 44: ("D", 4, "x")                     // pedal hi-hat
        case 46: ("G", 5, "x")                     // open hi-hat
        case 49, 57, 55, 52: ("A", 5, "x")         // crashes, splash, china
        case 51, 59: ("F", 5, "x")                 // rides
        case 53: ("F", 5, "diamond")               // ride bell
        case 56: ("E", 5, "triangle")              // cowbell
        default: ("C", 5, nil)
        }
    }

    /// One clef, or two staves split at middle C.
    enum StaffLayout: Equatable {
        case treble
        case bass
        case grand
        case percussion

        var staves: Int { self == .grand ? 2 : 1 }
    }

    /// The fewest notes a part needs before it can earn two staves, and the share of them that
    /// has to fall on each side of middle C.
    static let grandStaffMinimumNotes = 8
    static let grandStaffMinimumShare = 0.1

    /// Two staves for a part with a real presence on both sides of middle C; otherwise the
    /// clef its median pitch calls for.
    static func staffLayout(for pitches: [Int]) -> StaffLayout {
        guard !pitches.isEmpty else { return .treble }

        let below = pitches.filter { $0 < middleC }.count
        let above = pitches.count - below
        let share = Double(pitches.count) * grandStaffMinimumShare

        if pitches.count >= grandStaffMinimumNotes, Double(below) >= share, Double(above) >= share {
            return .grand
        }

        let median = pitches.sorted()[pitches.count / 2]

        return median >= middleC ? .treble : .bass
    }

    static let middleC = 60
}
