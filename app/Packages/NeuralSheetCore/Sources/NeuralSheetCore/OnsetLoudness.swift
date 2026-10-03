import Foundation

/// Velocity from the audio (editor commands design §2): the loudness of the model's mono copy
/// just after each note starts, mapped onto a velocity range so a passage keeps its dynamics
/// instead of the model's flat 100. Any thread; O(notes × window samples).
public enum OnsetLoudness {
    /// The model's copy is what is measured.
    public static let sampleRate = 16_000.0
    /// What silence, or a window past the end of the take, reads as.
    public static let floorDb = -80.0
    /// The quietest and the loudest onset among the notes get these.
    public static let lowVelocity = 24
    public static let highVelocity = 127
    /// A set with no spread (one note, or all equally loud) gets this, the model's own.
    public static let flatVelocity = 100

    /// The RMS of `window` seconds of `mono16k` from `atSeconds`, in dB, never under
    /// ``floorDb``.
    public static func measure(mono16k: [Float], atSeconds seconds: Double, window: Double = 0.05) -> Double {
        let start = max(0, Int((seconds * sampleRate).rounded()))
        let end = min(mono16k.count, start + max(1, Int((window * sampleRate).rounded())))

        guard start < end else { return floorDb }

        var sum = 0.0

        for index in start..<end {
            let sample = Double(mono16k[index])
            sum += sample * sample
        }

        let rms = (sum / Double(end - start)).squareRoot()

        guard rms > 0 else { return floorDb }

        return max(floorDb, 20 * log10(rms))
    }

    /// A velocity per onset, in order: linear from the quietest to the loudest onset onto
    /// ``lowVelocity``…``highVelocity``.
    public static func velocities(forOnsets onsets: [Double], mono16k: [Float], window: Double = 0.05) -> [Int] {
        velocities(forLevels: onsets.map { measure(mono16k: mono16k, atSeconds: $0, window: window) })
    }

    /// The mapping alone, from levels in dB. All equal (or one) gives ``flatVelocity`` each.
    public static func velocities(forLevels levels: [Double]) -> [Int] {
        guard let low = levels.min(), let high = levels.max() else { return [] }

        guard high - low > 1e-9 else { return levels.map { _ in flatVelocity } }

        let span = Double(highVelocity - lowVelocity)

        return levels.map { level in
            lowVelocity + Int(((level - low) / (high - low) * span).rounded())
        }
    }
}
