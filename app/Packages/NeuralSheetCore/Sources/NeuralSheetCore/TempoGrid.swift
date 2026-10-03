import Foundation

/// How fine the snap grid is, in quarter-note beats. Raw values are stable: the session stores them.
public enum GridDivision: String, CaseIterable, Codable, Sendable {
    case bar, half, quarter, eighth, sixteenth, thirtySecond, eighthTriplet, sixteenthTriplet

    public var label: String {
        switch self {
        case .bar: "1/1"
        case .half: "1/2"
        case .quarter: "1/4"
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        case .thirtySecond: "1/32"
        case .eighthTriplet: "1/8T"
        case .sixteenthTriplet: "1/16T"
        }
    }

    /// The division's length in quarter notes.
    public var beats: Double {
        switch self {
        case .bar: 4
        case .half: 2
        case .quarter: 1
        case .eighth: 0.5
        case .sixteenth: 0.25
        case .thirtySecond: 0.125
        case .eighthTriplet: 1.0 / 3.0
        case .sixteenthTriplet: 1.0 / 6.0
        }
    }
}

/// One line of the grid, for drawing.
public struct GridLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case bar, beat, division }

    public var seconds: Double
    public var kind: Kind

    public init(seconds: Double, kind: Kind) {
        self.seconds = seconds
        self.kind = kind
    }
}

/// The editor's tempo grid: a downbeat, a snap division and a tempo map (tempo map design §2).
///
/// The map is a list of segments, each starting on a bar line with a tempo and a meter; the first
/// always starts at bar 1, which falls at `offsetSeconds`. Time before it is bar 0, bar −1… at the
/// first segment's tempo and meter, so nothing is unreachable. Every consumer converts through
/// ``quarterBeats(atSeconds:)`` and ``seconds(atQuarterBeats:)`` (`TempoGrid+Map.swift`), so the
/// ruler, snap, the score and both exports agree on where every bar is.
///
/// `bpm` and `timeSignature` are the first segment's: the one-tempo paths read them unchanged.
public struct TempoGrid: Equatable, Codable, Sendable {
    public static let minBpm = 20.0
    public static let maxBpm = 999.0
    public static let defaultBpm = 120.0

    public var offsetSeconds: Double
    public var division: GridDivision

    /// Sorted by `startBar`, strictly increasing, the first at bar 1; kept so by the mutators.
    public internal(set) var segments: [GridSegment] {
        didSet { boundaries = TempoGrid.boundaries(of: segments) }
    }

    /// Where each segment starts, in quarter beats and seconds from bar 1: the conversions'
    /// lookup table, rebuilt whenever the segments change.
    private(set) var boundaries: [Boundary]

    struct Boundary: Equatable, Sendable {
        var beats: Double
        var seconds: Double
    }

    public init(bpm: Double = TempoGrid.defaultBpm, offsetSeconds: Double = 0, division: GridDivision = .sixteenth) {
        self.init(segments: [GridSegment(startBar: 1, bpm: bpm)], offsetSeconds: offsetSeconds, division: division)
    }

    /// A grid over `segments`, sanitised as ``replaceMap(_:offsetSeconds:)`` does.
    public init(segments: [GridSegment], offsetSeconds: Double = 0, division: GridDivision = .sixteenth) {
        let clean = TempoGrid.sanitised(segments)
        self.segments = clean
        self.boundaries = TempoGrid.boundaries(of: clean)
        self.offsetSeconds = max(0, offsetSeconds.isFinite ? offsetSeconds : 0)
        self.division = division
    }

    public static func == (lhs: TempoGrid, rhs: TempoGrid) -> Bool {
        lhs.offsetSeconds == rhs.offsetSeconds && lhs.division == rhs.division && lhs.segments == rhs.segments
    }

    /// The rule the export tempo field had: nothing sensible is 120, everything else is clamped.
    public static func clampedBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return defaultBpm }

        return min(max(bpm, minBpm), maxBpm)
    }

    // MARK: - The first segment

    /// The first segment's tempo: the one-tempo grid's BPM, and the tempo a MIDI file starts at.
    public var bpm: Double {
        get { segments[0].bpm }
        set { segments[0].bpm = TempoGrid.clampedBpm(newValue) }
    }

    /// The first segment's meter.
    public var timeSignature: TimeSignature {
        get { segments[0].timeSignature }
        set { segments[0].timeSignature = newValue }
    }

    /// Seconds per quarter note in the first segment.
    public var secondsPerBeat: Double { 60 / TempoGrid.clampedBpm(bpm) }

    /// Seconds per division in the first segment; ``step(atSeconds:)`` is the local one.
    public var step: Double { secondsPerBeat * division.beats }

    /// What the MIDI writer adds to every note time so the grid's bar lines land on the file's:
    /// the audio's downbeat shifted earlier by the offset, then forward by whole bars of the first
    /// segment until nothing would fall before tick 0. Zero when the offset is zero.
    public var exportStartOffsetSeconds: Double {
        let bar = segments[0].barSeconds
        guard bar > 0, offsetSeconds > 0 else { return 0 }
        return (offsetSeconds / bar).rounded(.up) * bar - offsetSeconds
    }

    /// `bar.beat`, as the ruler labels it.
    public func barBeatLabel(at seconds: Double) -> String {
        let position = barBeat(at: seconds)

        return "\(position.bar).\(position.beat)"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case offsetSeconds, division, segments, bpm }

    /// A payload without `segments` is a one-tempo grid from before the map: its `bpm` becomes
    /// one 4/4 segment (tempo map design §2).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let offset = try container.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0
        let division = try container.decodeIfPresent(GridDivision.self, forKey: .division) ?? .sixteenth

        if let segments = try container.decodeIfPresent([GridSegment].self, forKey: .segments), !segments.isEmpty {
            self.init(segments: segments, offsetSeconds: offset, division: division)
        } else {
            let bpm = try container.decodeIfPresent(Double.self, forKey: .bpm) ?? TempoGrid.defaultBpm
            self.init(bpm: bpm, offsetSeconds: offset, division: division)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offsetSeconds, forKey: .offsetSeconds)
        try container.encode(division, forKey: .division)
        try container.encode(segments, forKey: .segments)
    }

    // MARK: - Invariants

    /// Sorted, one segment per bar (the last given wins), every tempo clamped; the segment in
    /// force at bar 1 (the last at or before it, else the first) moved to bar 1 and anything
    /// before it dropped; empty becomes one 120 BPM 4/4 segment.
    static func sanitised(_ segments: [GridSegment]) -> [GridSegment] {
        var byBar: [Int: GridSegment] = [:]

        for var segment in segments {
            segment.bpm = clampedBpm(segment.bpm)
            byBar[segment.startBar] = segment
        }

        let sorted = byBar.keys.sorted().compactMap { byBar[$0] }
        let first = sorted.lastIndex { $0.startBar <= 1 } ?? 0
        var result = Array(sorted.dropFirst(first))

        guard !result.isEmpty else { return [GridSegment(startBar: 1, bpm: defaultBpm)] }

        result[0].startBar = 1

        return result
    }

    static func boundaries(of segments: [GridSegment]) -> [Boundary] {
        var result: [Boundary] = []
        result.reserveCapacity(segments.count)
        var beats = 0.0
        var seconds = 0.0

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let previous = segments[index - 1]
                let span = Double(segment.startBar - previous.startBar) * previous.timeSignature.quarterBeatsPerBar
                beats += span
                seconds += span * 60 / clampedBpm(previous.bpm)
            }

            result.append(Boundary(beats: beats, seconds: seconds))
        }

        return result
    }
}
