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

/// The editor's tempo grid: one tempo, one downbeat, 4/4 (what `MidiFileWriter` writes).
///
/// Bar 1 beat 1 falls at `offsetSeconds`; time before it is bar 0, bar −1…, so nothing is
/// unreachable. `bpm` is also the export tempo.
public struct TempoGrid: Equatable, Codable, Sendable {
    public static let minBpm = 20.0
    public static let maxBpm = 999.0
    public static let defaultBpm = 120.0
    public static let beatsPerBar = 4

    public var bpm: Double
    public var offsetSeconds: Double
    public var division: GridDivision

    public init(bpm: Double = TempoGrid.defaultBpm, offsetSeconds: Double = 0, division: GridDivision = .sixteenth) {
        self.bpm = TempoGrid.clampedBpm(bpm)
        self.offsetSeconds = max(0, offsetSeconds.isFinite ? offsetSeconds : 0)
        self.division = division
    }

    /// The rule the export tempo field had: nothing sensible is 120, everything else is clamped.
    public static func clampedBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return defaultBpm }

        return min(max(bpm, minBpm), maxBpm)
    }

    public var secondsPerBeat: Double { 60 / TempoGrid.clampedBpm(bpm) }

    /// Seconds per division.
    public var step: Double { secondsPerBeat * division.beats }

    /// The nearest grid line, never before 0.
    public func snap(_ seconds: Double) -> Double {
        max(0, offsetSeconds + ((seconds - offsetSeconds) / step).rounded() * step)
    }

    /// The grid line at or before `seconds`, never before 0.
    public func snapDown(_ seconds: Double) -> Double {
        max(0, offsetSeconds + ((seconds - offsetSeconds) / step).rounded(.down) * step)
    }

    /// Every line of `division` (this grid's by default) in `from...to`, at or after 0, in order.
    public func lines(from: Double, to: Double, division: GridDivision? = nil) -> [GridLine] {
        let division = division ?? self.division
        let step = secondsPerBeat * division.beats

        guard step > 0, to >= from else { return [] }

        let first = Int(((from - offsetSeconds) / step).rounded(.up))
        let last = Int(((to - offsetSeconds) / step).rounded(.down))

        guard first <= last else { return [] }

        var lines: [GridLine] = []
        lines.reserveCapacity(last - first + 1)

        for index in first...last {
            let seconds = offsetSeconds + Double(index) * step

            guard seconds >= 0 else { continue }

            let beats = Double(index) * division.beats
            let wholeBeats = beats.rounded()
            let kind: GridLine.Kind

            if abs(beats - wholeBeats) < 1e-9 {
                kind = Int(wholeBeats) % TempoGrid.beatsPerBar == 0 ? .bar : .beat
            } else {
                kind = .division
            }

            lines.append(GridLine(seconds: seconds, kind: kind))
        }

        return lines
    }

    /// 1-based bar and beat at `seconds`; bar 0 and below before the offset.
    public func barBeat(at seconds: Double) -> (bar: Int, beat: Int) {
        let beats = ((seconds - offsetSeconds) / secondsPerBeat + 1e-9).rounded(.down)
        let barIndex = (beats / Double(TempoGrid.beatsPerBar)).rounded(.down)
        let beatInBar = Int(beats - barIndex * Double(TempoGrid.beatsPerBar))

        return (Int(barIndex) + 1, beatInBar + 1)
    }

    /// `bar.beat`, as the ruler labels it.
    public func barBeatLabel(at seconds: Double) -> String {
        let position = barBeat(at: seconds)

        return "\(position.bar).\(position.beat)"
    }
}
