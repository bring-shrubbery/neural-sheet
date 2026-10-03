import AVFoundation
import Foundation
import NeuralSheetCore

/// The faders, mutes, solos and pans on the sub-mix inputs, the silencing a stop or a seek needs,
/// and the per-instrument meters. Main thread, except ``pushMeter(_:for:)`` on the tap thread;
/// none of it is reachable from the render block.
nonisolated extension InstrumentSynthBank {
    // MARK: - Silence

    /// CC 123 on both channels to every synth, the click's included, for a stop or a seek —
    /// including the drums, whose one-shot hits ignore the scheduler's note-offs.
    ///
    /// Any thread but the render thread: it takes the bank's lock. It also re-sends each synth's bank
    /// and program, because an AU's channel state does not necessarily survive the engine being
    /// reconfigured under it (a device change rebuilds the graph), and an instrument that had
    /// quietly reverted to program 0 would play the rest of the session as a piano.
    func allNotesOff() {
        lock.lock()
        let current = Array(instruments.values)
        lock.unlock()

        // CC 123 silences it with everything else; a timer that fires later finds nothing to stop.
        clearAudition()

        for instrument in current + [clickInstrument].compactMap({ $0 }) {
            sendAllNotesOff(to: instrument.node)
            sendProgramChange(to: instrument.node, program: instrument.program)
        }
    }

    /// CC 123 on both the melodic and the percussion channel.
    func sendAllNotesOff(to node: AVAudioUnitMIDIInstrument) {
        node.sendController(
            InstrumentSynthBank.allNotesOffController,
            withValue: 0,
            onChannel: InstrumentSynthBank.melodicChannel)
        node.sendController(
            InstrumentSynthBank.allNotesOffController,
            withValue: 0,
            onChannel: InstrumentSynthBank.drumChannel)
    }

    /// Bank select then program change, on the channel this instrument's notes arrive on. The
    /// click is a percussion kit like the drums (click design §2).
    func sendProgramChange(to node: AVAudioUnitMIDIInstrument, program: Int) {
        #if !os(macOS)
        // iOS's MIDI synth loads an instrument from its bank only for a program change it gets
        // while preloading, and must not be left preloading for playback; the change after the
        // preload is the one that selects it.
        Self.setPreload(true, on: node)
        sendBankAndProgram(to: node, program: program)
        Self.setPreload(false, on: node)
        #endif

        sendBankAndProgram(to: node, program: program)
    }

    #if !os(macOS)
    private static func setPreload(_ enabled: Bool, on node: AVAudioUnitMIDIInstrument) {
        var value: UInt32 = enabled ? 1 : 0

        AudioUnitSetProperty(
            node.audioUnit, kAUMIDISynthProperty_EnablePreload, kAudioUnitScope_Global, 0, &value,
            UInt32(MemoryLayout<UInt32>.size))
    }
    #endif

    private func sendBankAndProgram(to node: AVAudioUnitMIDIInstrument, program: Int) {
        if program >= NoteEvent.drumProgram {
            node.sendProgramChange(
                0,
                bankMSB: InstrumentSynthBank.drumBankMSB,
                bankLSB: 0,
                onChannel: InstrumentSynthBank.drumChannel)
        } else {
            node.sendProgramChange(
                UInt8(program),
                bankMSB: InstrumentSynthBank.melodicBankMSB,
                bankLSB: 0,
                onChannel: InstrumentSynthBank.melodicChannel)
        }
    }

    // MARK: - Mix

    /// Pushes the fader, mute, solo and pan state onto the sub-mix inputs. Main thread.
    ///
    /// Solo is derived here rather than stored as "the others are muted": `isAudible` is the one
    /// place that decision lives, and the piano roll dims its notes by the same answer. The pan is
    /// the node's own `AVAudioMixing` pan on its sub-mix input (click design §2).
    func apply(mixer: InstrumentMixerState) {
        // Kept so a synth created later starts where its instrument already is, rather than at
        // unity until the next call (``ensureInstrument(program:)``).
        appliedMixer = mixer

        lock.lock()
        defer { lock.unlock() }

        for instrument in instruments.values {
            let gain = InstrumentSynthBank.gain(for: instrument.program, in: mixer)

            instrument.gain = gain
            instrument.node.volume = gain
            instrument.node.pan = Float(mixer.pan(program: instrument.program))
        }
    }

    /// One instrument's mixer-input gain: the fader in linear terms, silenced outright when the
    /// fader is at its floor or the instrument is not currently heard.
    static func gain(for program: Int, in mixer: InstrumentMixerState) -> Float {
        let db = mixer.gainDb(program: program)

        return Float(linearGain(db: db) * (mixer.isAudible(program: program) ? 1 : 0))
    }

    /// A fader's dB as a linear gain, where −36 dB is the fader's silent end, not a very quiet one.
    static func linearGain(db: Double) -> Double {
        db <= InstrumentSynthBank.minGainDb ? 0 : pow(10.0, db / 20.0)
    }

    // MARK: - Meters

    /// One instrument's post-fader level over the meter window.
    func levelDb(program: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }

        return instruments[program]?.meter.decibels ?? RmsMeter.floorDb
    }

    /// Tap thread. Folds one synth's output to mono, scales it by the gain its mixer input is
    /// carrying — the tap is ahead of that input, so this is what makes the meter post-fader — and
    /// pushes it into that instrument's window.
    func pushMeter(_ buffer: AVAudioPCMBuffer, for program: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard let instrument = instruments[program], let data = buffer.floatChannelData,
            let scratch = instrument.scratch.baseAddress
        else { return }

        let frames = Swift.min(Int(buffer.frameLength), instrument.scratch.count)
        guard frames > 0 else { return }

        let gain = instrument.gain
        let channels = Int(buffer.format.channelCount)

        if channels >= 2 {
            let left = data[0]
            let right = data[1]
            for i in 0..<frames {
                scratch[i] = (left[i] + right[i]) * 0.5 * gain
            }
        } else {
            let mono = data[0]
            for i in 0..<frames {
                scratch[i] = mono[i] * gain
            }
        }

        instrument.meter.push(UnsafeBufferPointer(start: scratch, count: frames))
    }
}
