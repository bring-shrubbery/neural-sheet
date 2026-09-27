import Foundation
import NeuralSheetCore

/// The loop (loop design §5): the Loop button's toggle, and what the engine is told to repeat.
extension AppModel {
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
}
