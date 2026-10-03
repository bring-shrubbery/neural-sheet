import AVFoundation
import Foundation
import NeuralSheetCore

/// One transcribed instrument: its synth, the sub-mix input it feeds, and the meter after it.
///
/// Reached from the main thread and from the tap thread, both under ``InstrumentSynthBank``'s lock.
/// The render thread never sees it — it only reads the cached scheduling block out of the bank's
/// table.
nonisolated final class SynthInstrument: @unchecked Sendable {
    let program: Int
    let node: AVAudioUnitMIDIInstrument
    let bus: AVAudioNodeBus

    /// Post-fader: the tap is on the synth's own output, which is ahead of the mixer input's gain,
    /// so the meter has to apply that gain itself.
    var meter: RmsMeter

    /// What ``InstrumentSynthBank/apply(mixer:)`` last put on the mixer input.
    var gain: Float = 1

    /// The node's `scheduleMIDIEventBlock`, held here as well as in the bank's table so that the
    /// block and the audio unit it calls into have exactly one lifetime between them: retiring the
    /// instrument retires both.
    var scheduleBlock: AUScheduleMIDIEventBlock?

    /// Room to fold a tap buffer to mono without allocating on the tap thread.
    let scratch: UnsafeMutableBufferPointer<Float>

    init(
        program: Int, node: AVAudioUnitMIDIInstrument, bus: AVAudioNodeBus, sampleRate: Double,
        scratchFrames: Int
    ) {
        self.program = program
        self.node = node
        self.bus = bus
        self.meter = RmsMeter(sampleRate: sampleRate)

        scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0)
    }

    deinit {
        scratch.deallocate()
    }
}
