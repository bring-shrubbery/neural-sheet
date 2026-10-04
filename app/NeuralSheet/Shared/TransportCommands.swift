import Foundation
import NeuralSheetCore

/// The transport's arithmetic, shared by the Mac's `AppModel` and the iPhone and iPad's
/// `MobileModel` (iOS app design §3; sub-issue H): the SPEED pill's range and steps (speed design
/// §5), the mix keys' tenths and what the engine is told under the stereo split, and the stretch
/// the Loop button repeats (loop design §5). Pure: the models hold the state and push it to the
/// engine themselves.
nonisolated enum TransportCommands {
    // MARK: - Speed

    /// What the SPEED pill spans: half speed to one and a half, the take's own in the middle.
    static let speedRange = 0.5 ... 1.5

    /// What one press of `-` or `=` and one notch of the slider move the speed by.
    static let speedStep = 0.05

    /// A speed within ``speedRange``; anything that is not a number is the take's own.
    static func clampedSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(max(speed, speedRange.lowerBound), speedRange.upperBound) : 1
    }

    /// A step slower (`steps < 0`) or faster, landing on multiples of the step so a few presses
    /// from wherever the slider was left reach round numbers.
    static func nudgedSpeed(_ speed: Double, steps: Int) -> Double {
        let notches = ((speed + Double(steps) * speedStep) / speedStep).rounded()

        return min(max(notches * speedStep, speedRange.lowerBound), speedRange.upperBound)
    }

    // MARK: - Mix

    /// What one press of `[` or `]` moves the crossfade by.
    static let mixStep = 0.1

    /// A tenth toward the source (`steps < 0`) or the synth, landing on tenths so a few presses
    /// from wherever the slider was left reach either end exactly.
    static func nudgedMix(_ mix: Double, steps: Int) -> Double {
        let tenths = ((mix + Double(steps) * mixStep) / mixStep).rounded()

        return min(max(tenths * mixStep, 0), 1)
    }

    /// What the engine is told. Under the split the set mix means nothing -- both sides play at
    /// full -- so it gets the middle, or a hold's end to silence the other ear; otherwise the
    /// hold while there is one, the set mix when not.
    static func engineMix(mix: Double, hold: Double?, stereoSplit: Bool) -> Double {
        stereoSplit ? (hold ?? 0.5) : (hold ?? mix)
    }

    // MARK: - Loop

    /// The stretch the engine repeats: the marked range, or the whole take without one; nothing
    /// with the loop off or no take.
    static func loopWindow(enabled: Bool, duration: Double, range: Range<Double>?) -> Range<Double>? {
        enabled && duration > 0 ? (range ?? 0 ..< duration) : nil
    }
}
