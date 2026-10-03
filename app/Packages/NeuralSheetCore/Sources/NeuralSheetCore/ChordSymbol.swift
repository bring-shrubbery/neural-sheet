import Foundation

/// A chord's quality (chord symbols design §2): the thirteen the detector and the card offer,
/// in the order ties are broken in, simpler first. Raw values are stable: the project stores them.
public enum ChordQuality: String, CaseIterable, Codable, Sendable {
    case major, minor, diminished, augmented, sus2, sus4
    case sixth, minorSixth, dominantSeventh, majorSeventh, minorSeventh, halfDiminished, diminishedSeventh

    /// What follows the root in the symbol: "", "m", "dim", "aug", "sus2", "sus4", "6", "m6",
    /// "7", "maj7", "m7", "m7♭5", "dim7" (issue #16, requirement 7).
    public var suffix: String {
        switch self {
        case .major: ""
        case .minor: "m"
        case .diminished: "dim"
        case .augmented: "aug"
        case .sus2: "sus2"
        case .sus4: "sus4"
        case .sixth: "6"
        case .minorSixth: "m6"
        case .dominantSeventh: "7"
        case .majorSeventh: "maj7"
        case .minorSeventh: "m7"
        case .halfDiminished: "m7♭5"
        case .diminishedSeventh: "dim7"
        }
    }

    /// The chord tones as semitones above the root, the root first.
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        case .sus2: [0, 2, 7]
        case .sus4: [0, 5, 7]
        case .sixth: [0, 4, 7, 9]
        case .minorSixth: [0, 3, 7, 9]
        case .dominantSeventh: [0, 4, 7, 10]
        case .majorSeventh: [0, 4, 7, 11]
        case .minorSeventh: [0, 3, 7, 10]
        case .halfDiminished: [0, 3, 6, 10]
        case .diminishedSeventh: [0, 3, 6, 9]
        }
    }

    /// MusicXML's `<kind>` for the quality (chord symbols design §2).
    public var musicXMLKind: String {
        switch self {
        case .major: "major"
        case .minor: "minor"
        case .diminished: "diminished"
        case .augmented: "augmented"
        case .sus2: "suspended-second"
        case .sus4: "suspended-fourth"
        case .sixth: "major-sixth"
        case .minorSixth: "minor-sixth"
        case .dominantSeventh: "dominant"
        case .majorSeventh: "major-seventh"
        case .minorSeventh: "minor-seventh"
        case .halfDiminished: "half-diminished"
        case .diminishedSeventh: "diminished-seventh"
        }
    }

    /// Whether the third is minor: what decides how a root is spelled without a key.
    var isMinor: Bool { intervals.contains(3) }
}

/// A chord symbol (chord symbols design §2): a root pitch class, a quality, and a bass pitch
/// class when the chord is written over another of its tones.
public struct ChordSymbol: Equatable, Hashable, Codable, Sendable {
    /// Pitch class 0…11, C being 0.
    public var root: Int
    public var quality: ChordQuality
    /// The slash bass, 0…11; nil, or the root itself, writes no slash.
    public var bass: Int?

    public init(root: Int, quality: ChordQuality, bass: Int? = nil) {
        self.root = ChordSymbol.pitchClass(root)
        self.quality = quality
        self.bass = bass.map(ChordSymbol.pitchClass)
    }

    /// The pitch classes the chord sounds.
    public var pitchClasses: [Int] { quality.intervals.map { (root + $0) % 12 } }

    /// The bass when it differs from the root: what the slash names.
    public var slashBass: Int? { bass.flatMap { $0 == root ? nil : $0 } }

    /// "B♭m7/F": the root and bass spelled for `key` (``spelledPitchClass(_:in:minor:)``).
    public func name(in key: MusicalKey?) -> String {
        let flats = ChordSymbol.prefersFlats(root: root, minor: quality.isMinor, key: key)
        var text = ChordSymbol.noteName(root, flats: flats) + quality.suffix

        if let bass = slashBass {
            text += "/" + ChordSymbol.noteName(bass, flats: flats)
        }

        return text
    }

    /// Whether a chord on `root` is spelled with flats (chord symbols design §2): a key with flats
    /// in its signature spells flats, one with sharps spells sharps; without a key, or in C major
    /// and A minor which have neither, the root is spelled as the tonic of its own key would be
    /// (`MusicalKey`'s fifths rule), so B♭, E♭ and A♭ but F♯ and, for a minor chord, C♯ and G♯.
    /// The bass follows the root, so a symbol never mixes the two.
    static func prefersFlats(root: Int, minor: Bool, key: MusicalKey?) -> Bool {
        if let key, key.fifths != 0 { return key.fifths < 0 }

        return MusicalKey(tonic: root, mode: minor ? .minor : .major).fifths < 0
    }

    static func noteName(_ pitchClass: Int, flats: Bool) -> String {
        (flats ? MusicalKey.flatNames : MusicalKey.sharpNames)[ChordSymbol.pitchClass(pitchClass)]
    }

    static func pitchClass(_ value: Int) -> Int { ((value % 12) + 12) % 12 }
}

/// One chord of the list (chord symbols design §2): where it starts, in seconds so it survives a
/// grid change, and the chord, nil for "N.C.". It lasts until the next event or the take's end.
public struct ChordEvent: Equatable, Hashable, Codable, Sendable {
    public static let noChordText = "N.C."

    public var seconds: Double
    public var chord: ChordSymbol?

    public init(seconds: Double, chord: ChordSymbol?) {
        self.seconds = seconds
        self.chord = chord
    }

    /// What the lane and the score print: the symbol spelled for `key`, or "N.C.".
    public func text(in key: MusicalKey?) -> String {
        chord?.name(in: key) ?? ChordEvent.noChordText
    }
}

extension [ChordEvent] {
    /// The list as the project keeps it: in time order (a stable sort, so equal times keep their
    /// order), never before 0.
    public func sortedChords() -> [ChordEvent] {
        map { ChordEvent(seconds: Swift.max(0, $0.seconds.isFinite ? $0.seconds : 0), chord: $0.chord) }
            .enumerated()
            .sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds < $1.element.seconds : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The index of the event sounding at `seconds`: the last starting at or before it, or nil
    /// before the first.
    public func chordIndex(at seconds: Double) -> Int? {
        lastIndex { $0.seconds <= seconds }
    }
}
