import AVFoundation
import Foundation
import NeuralSheetCore

// Stub — implemented in Task 12.
//
// The real one owns an `AVAudioUnitMIDISynth` per transcribed program, a sub-mix carrying the
// per-instrument faders, and the `AUScheduleMIDIEventBlock` calls that put the scheduler's events on
// the timeline one cycle ahead. The interface is the one Task 12 fills in, so ``PlaybackEngine`` is
// written against the finished shape and does not change when the bodies arrive.
nonisolated final class InstrumentSynthBank: @unchecked Sendable {
    let scheduler = NoteScheduler()

    private let engine: AVAudioEngine
    private let mixTarget: AVAudioMixerNode

    /// The synth side of the equal-power crossfade, `sin(mix · π/2)`. Written from the main thread,
    /// applied by the bank to its sub-mix's input on ``mixTarget``.
    var synthGain: Float = 0

    init(engine: AVAudioEngine, mixTarget: AVAudioMixerNode) {
        self.engine = engine
        self.mixTarget = mixTarget
    }

    /// Creates the synth for `program` if it has none yet. Main thread.
    func ensureInstrument(program: Int) {
        _ = program
    }

    /// Render thread. Schedules everything in `[t0, t1)` one buffer ahead of `renderTime`.
    func schedule(
        from t0: Double, to t1: Double, renderTime: AudioTimeStamp, frameCount: Int,
        sampleRate: Double
    ) {
        _ = (t0, t1, renderTime, frameCount, sampleRate)
    }

    /// CC 123 to every synth, for a stop or a seek — including the drums, whose one-shot hits ignore
    /// the scheduler's note-offs.
    func allNotesOff() {}

    /// Pushes the fader, mute and solo state onto the sub-mix inputs. Main thread.
    func apply(mixer: InstrumentMixerState) {
        _ = mixer
    }

    /// One instrument's post-fader level over the meter window.
    func levelDb(program: Int) -> Double {
        _ = program
        return RmsMeter.floorDb
    }

    /// Drops every synth and every sounding note. Main thread.
    func reset() {}
}
