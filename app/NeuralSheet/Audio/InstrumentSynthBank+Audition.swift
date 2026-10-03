import AVFoundation
import Foundation
import NeuralSheetCore

/// The editor's audition: one note sounded now, outside the transport. Main thread; nothing here
/// touches the render path or its table.
nonisolated extension InstrumentSynthBank {
    /// Sounds one note now, outside the transport, for the editor: a click on a note, a note
    /// dragged onto another pitch, a velocity or instrument change. Note-on at once, note-off
    /// `seconds` later; a drum hit is one-shot and gets none. Main thread.
    ///
    /// Goes through the instrument's own synth, so its fader, mute, solo, pan and sound bank apply
    /// exactly as they do to the scheduled notes; the crossfade does not (``auditionLifted``), so
    /// it is heard whatever the mix. `startNote` is `MusicDeviceMIDIEvent`, which the AU takes from
    /// any thread.
    func audition(program: Int, pitch: Int, velocity: Int, seconds: Double) {
        guard (0...NoteEvent.drumProgram).contains(program), (0...127).contains(pitch) else { return }

        ensureInstrument(program: program)

        lock.lock()
        let node = instruments[program]?.node
        lock.unlock()

        guard let node else { return }

        stopAudition()

        let isDrum = program == NoteEvent.drumProgram
        let channel = isDrum ? InstrumentSynthBank.drumChannel : InstrumentSynthBank.melodicChannel
        let key = UInt8(pitch)

        // The lift before the note-on, so its first frames are not under a crossfade at zero.
        auditionLifted = true
        node.startNote(key, withVelocity: UInt8(Swift.min(Swift.max(velocity, 1), 127)), onChannel: channel)

        auditionGeneration &+= 1
        let generation = auditionGeneration
        audition = (program, key, isDrum, generation)

        DispatchQueue.main.asyncAfter(deadline: .now() + Swift.max(seconds, 0)) { [weak self] in
            guard let self, let audition = self.audition, audition.generation == generation else { return }

            self.stopAudition()
        }
    }

    /// The note-off for whatever ``audition(program:pitch:velocity:seconds:)`` left sounding, and
    /// the crossfade back in force. Main thread.
    func stopAudition() {
        guard let audition else { return }

        clearAudition()

        guard !audition.isDrum else { return }

        lock.lock()
        let node = instruments[audition.program]?.node
        lock.unlock()

        node?.stopNote(audition.pitch, onChannel: InstrumentSynthBank.melodicChannel)
    }

    /// Forgets the audition and drops the lift, for the paths that have already silenced it.
    func clearAudition() {
        audition = nil
        auditionLifted = false
    }
}
