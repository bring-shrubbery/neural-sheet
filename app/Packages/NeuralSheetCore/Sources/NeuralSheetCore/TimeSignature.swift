import Foundation

/// A meter: `numerator` beats of a `1/denominator` note (tempo map design §2). The tempo is
/// always counted in quarter notes, so the meter's job is the bar's length in quarters and where
/// its beats fall in it.
public struct TimeSignature: Equatable, Hashable, Codable, Sendable {
    public static let numerators = 1...32
    /// Powers of two a score can write; 32 is accepted from a file, the toolbar offers up to 16.
    public static let denominators = [1, 2, 4, 8, 16, 32]

    public private(set) var numerator: Int
    public private(set) var denominator: Int

    public static let common = TimeSignature(numerator: 4, denominator: 4)

    /// The menus' order: the meters most music is in first, then the rest.
    public static let presets: [TimeSignature] = [
        TimeSignature(numerator: 4, denominator: 4), TimeSignature(numerator: 3, denominator: 4),
        TimeSignature(numerator: 2, denominator: 4), TimeSignature(numerator: 6, denominator: 8),
        TimeSignature(numerator: 5, denominator: 4), TimeSignature(numerator: 7, denominator: 8),
        TimeSignature(numerator: 9, denominator: 8), TimeSignature(numerator: 12, denominator: 8),
    ]

    /// Out-of-range values are brought into range rather than refused: the numerator clamped, the
    /// denominator to the nearest power of two a score can write.
    public init(numerator: Int, denominator: Int) {
        self.numerator = min(max(numerator, TimeSignature.numerators.lowerBound), TimeSignature.numerators.upperBound)
        self.denominator = TimeSignature.denominators.min { abs($0 - denominator) < abs($1 - denominator) } ?? 4
    }

    /// The bar's length in quarter notes: 3/4 is 3, 6/8 is 3, 7/8 is 3.5.
    public var quarterBeatsPerBar: Double { Double(numerator) * 4 / Double(denominator) }

    /// One beat (one `1/denominator` note) in quarter notes.
    public var beatLength: Double { 4 / Double(denominator) }

    /// "3/4".
    public var label: String { "\(numerator)/\(denominator)" }

    /// 6/8, 9/8, 12/8 and their kin: felt in dotted beats of three, which is how the metronome
    /// mark is printed (tempo map design §2).
    public var isCompound: Bool { numerator > 3 && numerator % 3 == 0 && denominator >= 8 }

    /// The note the metronome mark counts: a dotted `2/denominator` note in a compound meter, a
    /// quarter otherwise. `type` is MusicXML's name for the undotted value; `quarters` its length.
    public var metronomeUnit: (type: String, dotted: Bool, quarters: Double) {
        guard isCompound else { return ("quarter", false, 1) }

        let quarters = 3 * beatLength
        switch denominator {
        case 8: return ("quarter", true, quarters)
        case 16: return ("eighth", true, quarters)
        default: return ("16th", true, quarters)
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case numerator, denominator }

    /// Through the initialiser, so a hand-edited file cannot carry a meter the grid cannot draw.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(numerator: try container.decode(Int.self, forKey: .numerator),
                  denominator: try container.decode(Int.self, forKey: .denominator))
    }
}

/// One stretch of the tempo map: from bar `startBar` (1-based) to the next segment's start, at
/// `bpm` quarter notes a minute in `timeSignature` (tempo map design §2).
public struct GridSegment: Equatable, Codable, Sendable {
    public var startBar: Int
    public var bpm: Double
    public var timeSignature: TimeSignature

    public init(startBar: Int, bpm: Double, timeSignature: TimeSignature = .common) {
        self.startBar = startBar
        self.bpm = bpm
        self.timeSignature = timeSignature
    }

    /// One bar in seconds.
    public var barSeconds: Double { timeSignature.quarterBeatsPerBar * 60 / TempoGrid.clampedBpm(bpm) }
}
