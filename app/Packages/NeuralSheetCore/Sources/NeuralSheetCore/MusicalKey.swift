import Foundation

/// A major or natural-minor key (key design §3): its tonic, its signature, its name spelled by
/// the signature, and the scale it stands for.
public struct MusicalKey: Equatable, Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case major, minor

        public var name: String {
            switch self {
            case .major: "major"
            case .minor: "minor"
            }
        }
    }

    /// Pitch class 0…11, C being 0.
    public var tonic: Int
    public var mode: Mode

    public init(tonic: Int, mode: Mode) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.mode = mode
    }

    /// The same mode from the tonic `semitones` away: the written key of a transposing part.
    public func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: tonic + semitones, mode: mode)
    }

    // MARK: - Signature and names

    /// The key signature as sharps (positive) or flats (negative). F♯ major is +6, E♭ minor −6.
    public var fifths: Int {
        switch mode {
        case .major: MusicalKey.majorFifths[tonic]
        case .minor: MusicalKey.minorFifths[tonic]
        }
    }

    /// Major, by tonic pitch class: C G D A E B F♯ take sharps; D♭ A♭ E♭ B♭ F take flats.
    private static let majorFifths = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
    /// Minor, by tonic pitch class: A E B F♯ C♯ G♯ take sharps; E♭ B♭ F C G D take flats.
    private static let minorFifths = [-3, 4, -1, -6, 1, -4, 3, -2, 5, 0, -5, 2]

    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// "E♭", spelled by the signature.
    public var tonicName: String {
        (fifths < 0 ? MusicalKey.flatNames : MusicalKey.sharpNames)[tonic]
    }

    /// "E♭ minor".
    public var name: String { "\(tonicName) \(mode.name)" }

    /// How the tonic menu names a pitch class before a mode has spelled it: both names where
    /// two apply.
    public static func tonicMenuName(_ pitchClass: Int) -> String {
        let pc = ((pitchClass % 12) + 12) % 12
        let sharp = sharpNames[pc]
        let flat = flatNames[pc]

        return sharp == flat ? sharp : "\(sharp) / \(flat)"
    }

    // MARK: - Scale

    private static let majorSteps = [0, 2, 4, 5, 7, 9, 11]
    private static let minorSteps = [0, 2, 3, 5, 7, 8, 10]

    /// The scale's pitch classes, ascending from C.
    public var scalePitchClasses: [Int] {
        let steps = mode == .major ? MusicalKey.majorSteps : MusicalKey.minorSteps

        return steps.map { ($0 + tonic) % 12 }.sorted()
    }

    public func contains(pitch: Int) -> Bool {
        scalePitchClasses.contains(((pitch % 12) + 12) % 12)
    }

    public func isTonic(pitch: Int) -> Bool {
        ((pitch % 12) + 12) % 12 == tonic
    }

    /// The scale pitch nearest `pitch`; a pitch between two scale degrees goes to the lower.
    public func nearestScalePitch(_ pitch: Int) -> Int {
        guard !contains(pitch: pitch) else { return pitch }

        // Every gap in a diatonic scale is a tone or a semitone, so a non-scale pitch has a scale
        // pitch a semitone either side.
        let below = pitch - 1
        let above = pitch + 1

        if contains(pitch: below), below >= 0 { return below }
        if contains(pitch: above), above <= 127 { return above }

        return pitch
    }
}
