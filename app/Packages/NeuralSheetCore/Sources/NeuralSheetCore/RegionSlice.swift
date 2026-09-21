/// The stretch of audio a region re-run is given (design §5.3, §5.4): the marked range widened
/// by the context margin on each side and clamped to the take. The lead-in is what lets a note
/// already sounding at the range start be decoded with its onset before the range, and dropped;
/// the tail lets the model place the offset of a note that runs past the end.
public struct RegionSlice: Equatable, Sendable {
    /// Seconds of audio the model sees before the range and after it.
    public static let contextSeconds = 2.0
    /// The shortest range worth a run.
    public static let minimumRangeSeconds = 0.1
    /// The model's only sample rate.
    public static let sampleRate = 16_000

    /// Seconds from the start of the take.
    public var start: Double
    public var end: Double

    /// Nil for a range under the minimum, a take with no length, or a range starting past the
    /// take's end. A range running off the end is clamped.
    public init?(range: Range<Double>, duration: Double, context: Double = RegionSlice.contextSeconds) {
        guard range.upperBound - range.lowerBound >= RegionSlice.minimumRangeSeconds,
              duration > 0, range.lowerBound < duration
        else { return nil }

        start = max(0, range.lowerBound - context)
        end = min(duration, range.upperBound + context)
    }

    /// The slice as indices into a 16 kHz signal of `sampleCount` samples, never past its end.
    public func sampleRange(sampleCount: Int) -> Range<Int> {
        let rate = Double(RegionSlice.sampleRate)
        let lower = min(max(Int((start * rate).rounded()), 0), sampleCount)
        let upper = min(max(Int((end * rate).rounded()), lower), sampleCount)

        return lower ..< upper
    }
}
