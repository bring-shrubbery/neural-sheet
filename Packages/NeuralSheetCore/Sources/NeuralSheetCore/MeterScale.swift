/// How a level becomes lit segments, and which band a segment belongs to.
///
/// Pure arithmetic, kept out of the view so the strip's 16 segments and the master's 26 cannot end
/// up on different scales.
public enum MeterScale {
    /// What the meters show, which is not what the faders span: the gain range runs to +6 dB and
    /// its floor stands for silence, whereas a meter needs a bottom it can actually reach and a top
    /// at clipping. Deliberately its own pair of constants rather than the mixer's.
    public static let minDb = -36.0
    public static let maxDb = 0.0

    /// Where a segment stops being green, and where it becomes hot.
    public static let midDb = -12.0
    public static let hotDb = -6.0

    /// The scale in whole decibels, which is what the band boundaries divide.
    public static let rangeDb = 36
    public static let midAboveFloorDb = 24
    public static let hotAboveFloorDb = 30

    /// How many segments a level lights. Rounded, so a segment is drawn whole or not at all.
    public static func litSegments(db: Double, count: Int) -> Int {
        guard db.isFinite, count > 0 else { return 0 }

        let normalised = (db - minDb) / Double(rangeDb)
        let lit = (normalised * Double(count)).rounded()

        // Clamped as a Double: a level far off the scale would otherwise overflow the conversion.
        return Int(min(max(lit, 0), Double(count)))
    }

    public enum Band: Equatable, Sendable {
        case low, mid, hot
    }

    /// The band a segment belongs to: a band starts at the segment whose dB span contains its
    /// threshold, which the truncating division below is exactly the index of. Compared in integers
    /// so the boundary is a segment index rather than a hair either side of a float threshold.
    ///
    /// Deriving it from dB rather than from the index is what keeps the two meter sizes on the same
    /// scale: 0-16 / 17-20 / 21-25 at N = 26, 0-9 / 10-12 / 13-15 at N = 16. Not the same level to
    /// the decibel, though, and it cannot be — no segment boundary lands on -12 or -6 at either
    /// size, and ``litSegments(db:count:)`` rounds, so the segment lights at the middle of its span.
    public static func band(segment: Int, count: Int) -> Band {
        if segment >= hotAboveFloorDb * count / rangeDb { return .hot }
        if segment >= midAboveFloorDb * count / rangeDb { return .mid }

        return .low
    }
}

/// A meter's smoothing: instant attack so a hit reads on the frame it lands, and a release slow
/// enough to follow with the eye rather than reading as a flicker, quick enough that a mute reads
/// as off — the whole range drains in a second and a half.
public struct MeterBallistics {
    public static let releaseDbPerSecond = 24.0

    /// The longest frame the release will act on, so a stalled frame does not drop the meter by a
    /// whole range at once.
    public static let maxFrameSeconds = 0.1

    /// Where the meter is now, in dB. Starts at the bottom of the scale.
    public private(set) var value = MeterScale.minDb

    public init() {}

    /// Advances the meter by one frame and returns its new level.
    @discardableResult
    public mutating func advance(input: Double, dt: Double) -> Double {
        // Clamped to the top of the scale: a level above it looks the same, but left in `value` it
        // would hold the meter fully lit for however long the release takes to walk back into
        // range. A level that is not a number is read as silence rather than spread around.
        let instant = input.isFinite ? min(input, MeterScale.maxDb) : MeterScale.minDb
        let seconds = dt.isFinite ? min(max(dt, 0), MeterBallistics.maxFrameSeconds) : 0

        if instant >= value {
            value = instant
        } else {
            value = max(instant, value - MeterBallistics.releaseDbPerSecond * seconds)
        }

        return value
    }
}
