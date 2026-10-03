import AVFoundation
import Foundation
import NeuralSheetCore

/// The MIDI output's iOS stand-in: MIDI out is a follow-up on iOS (iOS app design §1), so the
/// Mac's CoreMIDI client, sender thread and ring (`MidiOutput.swift`, `MidiOutput+Sender.swift`,
/// `MidiOutRing.swift`) are left out of this target and this answers the calls the shared audio
/// layer makes with nothing sent. It never sends, as the Mac's offline output never does.
nonisolated final class MidiOutput: @unchecked Sendable {
    let isConnected = false

    init(connected: Bool = true) {
        _ = connected
    }

    var isSending: Bool { false }

    func panic() {}

    func resendControls() {}

    func sendNote(program: Int, pitch: Int, velocity: Int) {
        _ = (program, pitch, velocity)
    }

    func shutDown() {}
}

/// The bank's side of the MIDI output (`InstrumentSynthBank+MidiOut.swift` on the Mac), with
/// nothing to push to.
nonisolated extension InstrumentSynthBank {
    /// Render thread: nothing, as the Mac's push is one load that finds nothing when no
    /// destination is chosen.
    @inline(__always)
    func pushMidiOut(_ collected: [SynthEvent], renderTime: AudioTimeStamp, frameCount: Int, outputRate: Double) {}

    /// Main thread. Kept so callers shared with the Mac compile; nothing on iOS mutes for MIDI out.
    func setSynthMutedForMidiOut(_ muted: Bool) {
        if synthMutedForMidiOut != muted { synthMutedForMidiOut = muted }
    }
}
