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
        let loop = TransportCommands.loopWindow(enabled: loopEnabled, duration: duration, range: editor.range)

        if engine.loop != loop {
            engine.loop = loop
        }
    }

    // MARK: - Speed

    /// The keys: a step slower (`steps < 0`) or faster (`TransportCommands.nudgedSpeed`).
    func nudgeSpeed(steps: Int) {
        playbackSpeed = TransportCommands.nudgedSpeed(playbackSpeed, steps: steps)
    }

    /// The slider's double-click: the take's own speed.
    func resetSpeed() {
        playbackSpeed = 1
    }
}
