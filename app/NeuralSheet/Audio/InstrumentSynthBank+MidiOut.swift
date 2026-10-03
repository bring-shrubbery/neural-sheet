import AVFoundation
import Darwin
import Foundation
import NeuralSheetCore
import Synchronization

/// The bank's side of the live MIDI output (MIDI out design §3): the render thread's push of the
/// scheduler's events into the output's ring, and the main thread's synth mute.
nonisolated extension InstrumentSynthBank {
    // MARK: - Render thread

    /// Render thread. When a destination is chosen, each of the block's instrument events goes
    /// into the MIDI output's ring with the buffer's host time and its frames from it -- the same
    /// buffer of lead the synths are scheduled with, then the event's offset -- and the sender is
    /// woken once.
    ///
    /// One atomic load when nothing is being sent. Otherwise a few stores and one releasing store
    /// per event (``MidiOutRing/push(_:)``) and one `DispatchSemaphore.signal()`: no allocation, no
    /// lock, no CoreMIDI call, no Objective-C. `mach_absolute_time()` stands in for a host time the
    /// timestamp does not carry, so an event is never sent "now", a buffer early.
    ///
    /// Drum note-offs go too, unlike to the synth: a DAW's drum track records the note's length,
    /// and the file the export writes carries them.
    func pushMidiOut(_ collected: [SynthEvent], renderTime: AudioTimeStamp, frameCount: Int, outputRate: Double) {
        let output = midiOut
        guard !collected.isEmpty, output.sending.load(ordering: .relaxed) else { return }

        let ring = output.ring
        let hostTime = renderTime.mFlags.contains(.hostTimeValid) ? renderTime.mHostTime : mach_absolute_time()
        let lead = Swift.max(frameCount, 0)
        var pushed = false

        collected.withUnsafeBufferPointer { collected in
            for event in collected where event.program >= 0 && event.program <= NoteEvent.drumProgram {
                let entry = MidiOutEntry(
                    hostTime: hostTime,
                    frames: Int32(clamping: lead + Swift.max(event.sampleOffset, 0)),
                    sampleRate: outputRate,
                    program: UInt8(event.program),
                    pitch: UInt8(Swift.min(Swift.max(event.pitch, 0), 127)),
                    velocity: event.isOn ? event.velocity : 0,
                    isOn: event.isOn)

                if ring.push(entry) { pushed = true }
            }
        }

        if pushed { output.signal() }
    }

    // MARK: - Main thread

    /// Mute Built-in Synth While Sending, in force: the sub-mix silent while `muted` (MIDI out
    /// design §2). Main thread.
    func setSynthMutedForMidiOut(_ muted: Bool) {
        if synthMutedForMidiOut != muted { synthMutedForMidiOut = muted }
    }
}
