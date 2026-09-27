import Foundation

/// Where a pitch sits on a staff (score design §3): diatonic steps from a clef's bottom line,
/// the key signature's positions, and which accidental a spelled note shows under a key.
public enum Clef: Equatable, Sendable {
    case treble, bass, percussion

    /// The diatonic number of the bottom line: E4 for the treble staff, G2 for the bass; the
    /// percussion staff places its display positions as the treble does.
    var baseline: Int {
        switch self {
        case .treble, .percussion: ScorePitch.diatonic(step: "E", octave: 4)
        case .bass: ScorePitch.diatonic(step: "G", octave: 2)
        }
    }

    /// Staff steps from the bottom line (0), a step per line or space, negative below.
    public func step(forStep letter: String, octave: Int) -> Int {
        ScorePitch.diatonic(step: letter, octave: octave) - baseline
    }

    /// The staff steps the key signature's accidentals sit on, in signature order.
    public func signaturePositions(fifths: Int) -> [Int] {
        guard fifths != 0 else { return [] }

        let count = min(abs(fifths), 7)

        switch (self, fifths > 0) {
        case (.bass, true):
            return ScorePitch.trebleSharps.prefix(count).map { $0 - 2 }
        case (.bass, false):
            return ScorePitch.trebleFlats.prefix(count).map { $0 - 2 }
        case (_, true):
            return Array(ScorePitch.trebleSharps.prefix(count))
        case (_, false):
            return Array(ScorePitch.trebleFlats.prefix(count))
        }
    }
}

/// What a note shows beside its head.
public enum Accidental: Equatable, Sendable {
    case sharp, flat, natural
}

enum ScorePitch {
    static let letters = ["C", "D", "E", "F", "G", "A", "B"]

    /// Letters counted from C0, seven to the octave.
    static func diatonic(step: String, octave: Int) -> Int {
        octave * 7 + (letters.firstIndex(of: step) ?? 0)
    }

    /// The treble staff's sharp positions F5 C5 G5 D5 A4 E5 B4 and flat positions B4 E5 A4 D5
    /// G4 C5 F4, as steps from the bottom line. The bass staff's are two steps lower.
    static let trebleSharps = [8, 5, 9, 6, 3, 7, 4]
    static let trebleFlats = [4, 7, 3, 6, 2, 5, 1]

    /// The letters a signature alters, in order: sharps F C G D A E B, flats B E A D G C F.
    static let sharpOrder = ["F", "C", "G", "D", "A", "E", "B"]
    static let flatOrder = ["B", "E", "A", "D", "G", "C", "F"]

    /// The accidental a note spelled `alter` on `letter` shows under a signature: none when the
    /// signature already says so, a natural when the signature alters the letter and the note
    /// does not.
    static func accidental(letter: String, alter: Int, fifths: Int) -> Accidental? {
        let signatureAlter = MusicalKey.alteredSteps(fifths: fifths)[letter] ?? 0

        guard alter != signatureAlter else { return nil }

        switch alter {
        case 1: return .sharp
        case -1: return .flat
        default: return .natural
        }
    }
}

extension MusicalKey {
    /// The letters a signature of `fifths` alters, and by what: G major's `["F": 1]`.
    public static func alteredSteps(fifths: Int) -> [String: Int] {
        let count = min(abs(fifths), 7)
        let order = fifths > 0 ? ScorePitch.sharpOrder : ScorePitch.flatOrder
        var altered: [String: Int] = [:]

        for letter in order.prefix(count) {
            altered[letter] = fifths > 0 ? 1 : -1
        }

        return altered
    }

    public var alteredSteps: [String: Int] { MusicalKey.alteredSteps(fifths: fifths) }
}
