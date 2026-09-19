import Foundation

/// A sliding mean square over the last window of samples, for driving a level meter.
///
/// A circular buffer of squared samples plus a running sum: each sample subtracts the one leaving
/// the window and adds the one entering, so the cost per sample is constant however long the
/// window is, and the value is exact at every sample rather than once per block.
///
/// Threading: ``push(_:)`` and ``pushSilence(count:)`` are the audio thread's and allocate nothing
/// — the window is allocated once, in ``init(sampleRate:windowSeconds:)``, and never resized.
/// Nothing here is atomic; the owner publishes ``decibels`` once per block into an atomic of its
/// own, which is what the UI reads.
///
/// The window lives behind a reference, so a copy of an `RmsMeter` shares it rather than taking a
/// snapshot: one meter is one signal's window, and it is passed around, never duplicated.
public struct RmsMeter {
    /// The meters' integration time. Long enough to read as a level rather than as a waveform.
    public static let defaultWindowSeconds = 0.05

    /// The value ``decibels`` reports for silence, and the floor it never reads below.
    public static let floorDb = -100.0

    private final class Window {
        let squares: UnsafeMutableBufferPointer<Float>
        // The running sum is a double: a float one accumulates rounding across millions of
        // add/subtract pairs and drifts away from the window it is meant to describe.
        var sum = 0.0
        var write = 0
        // A fresh window is silent, so pushSilence has nothing to do until something is pushed.
        var zeroRun: Int

        init(size: Int) {
            squares = UnsafeMutableBufferPointer<Float>.allocate(capacity: size)
            squares.initialize(repeating: 0)
            zeroRun = size
        }

        deinit {
            squares.deallocate()
        }
    }

    private let window: Window

    /// Allocates the window. The message thread's, and only where the audio callback cannot run.
    public init(sampleRate: Double, windowSeconds: Double = RmsMeter.defaultWindowSeconds) {
        let samples = (sampleRate * windowSeconds).rounded()
        // At least one sample, so the meter always has something to report; bounded above so a
        // nonsense sample rate cannot ask for an unallocatable window.
        let size = samples.isFinite ? Int(min(max(samples, 1), 1e8)) : 1

        window = Window(size: size)
    }

    /// How many samples the window spans.
    public var windowSamples: Int { window.squares.count }

    /// Audio thread. One mono buffer into the window.
    public mutating func push(_ samples: UnsafeBufferPointer<Float>) {
        let size = window.squares.count

        guard size > 0, !samples.isEmpty else { return }

        var sum = window.sum
        var write = window.write

        for sample in samples {
            let square = sample * sample

            sum += Double(square) - Double(window.squares[write])
            window.squares[write] = square

            write += 1
            if write >= size { write = 0 }
        }

        window.sum = sum
        window.write = write
        window.zeroRun = 0
    }

    /// Audio thread. `count` samples of silence, touching no memory once the window is already all
    /// zeros — which is what makes an instrument that is not sounding cost nothing.
    public mutating func pushSilence(count: Int) {
        let size = window.squares.count

        guard size > 0, count > 0, window.zeroRun < size else { return }

        // Past a full window every entry it could evict is already a zero, so the extra writes
        // would be a no-op and the write position they would leave behind does not matter.
        let num = min(count, size)

        for _ in 0..<num {
            window.sum -= Double(window.squares[window.write])
            window.squares[window.write] = 0

            window.write += 1
            if window.write >= size { window.write = 0 }
        }

        window.zeroRun = min(window.zeroRun + num, size)

        if window.zeroRun >= size {
            // Exactly zero rather than whatever the subtractions rounded to, so silence reads as
            // silence and the residue is cleared every time the signal stops.
            window.sum = 0
        }
    }

    /// Never negative: rounding can leave the sum a hair below zero, and NaN dB spreads from there.
    public var meanSquare: Double {
        let size = window.squares.count

        guard size > 0, window.sum > 0 else { return 0 }

        return window.sum / Double(size)
    }

    /// The window's level, `10 * log10(meanSquare)`, floored at ``floorDb`` so silence is a number.
    public var decibels: Double {
        let power = meanSquare

        guard power > 0 else { return RmsMeter.floorDb }

        return max(RmsMeter.floorDb, 10 * log10(power))
    }
}
