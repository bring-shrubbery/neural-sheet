import Foundation

/// The tempo from presses in time with the music (tempo design §3.1): the median interval of the
/// last few taps, as BPM. Times are the take's own seconds, so tapping along at half speed still
/// reads the take's tempo.
public struct TapTempo: Equatable, Sendable {
    /// An interval outside these is not a beat: the press starts a new series.
    public static let minInterval = 0.25
    public static let maxInterval = 2.0
    /// How many taps the estimate is taken over.
    public static let window = 8

    private var taps: [Double] = []

    public init() {}

    /// Records a tap and returns the BPM, rounded to the integer and clamped to the grid's range,
    /// or nil until there are two taps in a row.
    public mutating func tap(at seconds: Double) -> Double? {
        guard seconds.isFinite else { return nil }

        if let last = taps.last {
            let interval = seconds - last

            if interval < TapTempo.minInterval || interval > TapTempo.maxInterval {
                taps.removeAll(keepingCapacity: true)
            }
        }

        taps.append(seconds)

        if taps.count > TapTempo.window {
            taps.removeFirst(taps.count - TapTempo.window)
        }

        guard taps.count >= 2 else { return nil }

        let intervals = zip(taps.dropFirst(), taps).map { $0 - $1 }.sorted()
        let middle = intervals.count / 2
        let median = intervals.count % 2 == 0
            ? (intervals[middle - 1] + intervals[middle]) / 2
            : intervals[middle]

        guard median > 0 else { return nil }

        return TempoGrid.clampedBpm((60 / median).rounded())
    }

    public mutating func reset() {
        taps.removeAll(keepingCapacity: true)
    }
}
