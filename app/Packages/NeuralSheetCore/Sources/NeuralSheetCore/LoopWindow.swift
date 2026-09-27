import Foundation

/// The stretch of the take playback repeats, in frames at the device rate (loop design §3): the
/// arithmetic the render block asks after each block, and a packing of both ends into one word so
/// they cross to the render thread in a single atomic load.
public struct LoopWindow: Equatable, Sendable {
    /// The first frame of the loop.
    public var start: Int
    /// One past the last frame of the loop; `end > start`.
    public var end: Int

    public var length: Int { end - start }

    /// Nil unless `0 <= start < end`.
    public init?(start: Int, end: Int) {
        guard start >= 0, end > start else { return nil }

        self.start = start
        self.end = end
    }

    /// The seconds rounded to frames and clamped to the take. Nil with no take, a rate that is
    /// not positive, a range starting at or past the take's end, or one that rounds to nothing.
    public init?(seconds: Range<Double>, sampleRate: Double, frameCount: Int) {
        guard sampleRate > 0, frameCount > 0, seconds.lowerBound.isFinite, seconds.upperBound.isFinite
        else { return nil }

        let start = min(max(Int((seconds.lowerBound * sampleRate).rounded()), 0), frameCount)
        let end = min(max(Int((seconds.upperBound * sampleRate).rounded()), 0), frameCount)

        self.init(start: start, end: end)
    }

    /// `position` folded back into the loop once it has reached the end, however many times the
    /// overshoot spans the loop. A position before the start is left where it is: the transport
    /// may be playing into the loop.
    public func wrapped(_ position: Int) -> Int {
        guard position >= end else { return position }

        return start + (position - end) % length
    }

    /// What a block of `frames` starting at `playhead` does to the transport: `renderEnd` is the
    /// frame the synth is scheduled up to, the loop's end when the block crosses it from inside;
    /// `next` is where the following block starts, the overshoot folded past the start. A block
    /// starting at or past the end -- the loop was set behind the playhead -- plays as it was
    /// and then goes to the start.
    public func advance(from playhead: Int, frames: Int) -> (renderEnd: Int, next: Int) {
        let blockEnd = playhead + frames

        guard playhead < end else { return (blockEnd, start) }

        return (min(blockEnd, end), wrapped(blockEnd))
    }

    /// Both ends in one 64-bit word, `start` in the high half; never 0, which stands for no loop.
    /// Frame counts fit the half-words up to a day of audio at 48 kHz.
    public var packed: UInt64 {
        UInt64(UInt32(truncatingIfNeeded: start)) << 32 | UInt64(UInt32(truncatingIfNeeded: end))
    }

    public init?(packed: UInt64) {
        guard packed != 0 else { return nil }

        self.init(start: Int(packed >> 32), end: Int(packed & 0xFFFF_FFFF))
    }
}
