import Foundation
import NeuralSheetCore

/// The practice controls: the loop (loop design §5) and the playback speed (speed design §5).
/// Both transient; neither is in the project file.
extension AppModel {
    // MARK: - Loop

    /// The Loop button and the `l` key: only over a take that can play.
    func toggleLoop() {
        guard state.canPlay else { return }

        loopEnabled.toggle()
        applyLoop()
    }

    /// The stretch the engine repeats: the marked range, or the whole take without one; nothing
    /// with the loop off or no take. Called whenever any of those change -- the toggle, the
    /// range through `editor`'s `didSet`, the take through `duration`'s -- and only written to
    /// the engine when it differs, since the duration ticks up throughout a recording.
    func applyLoop() {
        let loop: Range<Double>? = loopEnabled && duration > 0 ? (editor.range ?? 0 ..< duration) : nil

        if engine.loop != loop {
            engine.loop = loop
        }
    }

    // MARK: - Speed

    /// What the SPEED pill spans: half speed to one and a half, the take's own in the middle.
    static let speedRange = 0.5 ... 1.5

    /// What one press of `-` or `=` and one notch of the slider move the speed by.
    static let speedStep = 0.05

    /// The keys: a step slower (`steps < 0`) or faster, landing on multiples of the step so a
    /// few presses from wherever the slider was left reach round numbers.
    func nudgeSpeed(steps: Int) {
        let notches = ((playbackSpeed + Double(steps) * AppModel.speedStep) / AppModel.speedStep).rounded()

        playbackSpeed = min(max(notches * AppModel.speedStep, AppModel.speedRange.lowerBound), AppModel.speedRange.upperBound)
    }

    /// The slider's double-click: the take's own speed.
    func resetSpeed() {
        playbackSpeed = 1
    }
}
