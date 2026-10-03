import Foundation
import NeuralSheetCore

/// Audio → MIDI Output (MIDI out design §2, §5): the destinations the menu lists, the choice and
/// its memory across launches, the synth mute, and the channel map and mixer the output follows.
/// Views reach the output only through these.
extension AppModel {
    // MARK: - Setup

    /// From `init`: the menu's list follows CoreMIDI's setup changes, and the remembered
    /// destination is chosen again if it is there. A missing one is None, silently, until it
    /// appears.
    func startMidiOut() {
        engine.synthBank.midiOut.onSetupChanged = { [weak self] in
            self?.refreshMidiDestinations()
        }

        refreshMidiDestinations()
    }

    // MARK: - Destinations

    /// Re-reads CoreMIDI's destinations: when the menu opens and on every setup change. The
    /// remembered destination is reconnected when it comes back, and its endpoint looked up again.
    func refreshMidiDestinations() {
        let destinations = MidiOutput.destinations()

        if destinations != midiDestinations {
            midiDestinations = destinations
        }

        guard let uniqueID = settings.midiOutUniqueID else { return }

        let available = destinations.first { $0.uniqueID == uniqueID }

        if available != midiOutDestination {
            connectMidiOut(to: available)
        }
    }

    /// The menu's pick, remembered by unique id; nil is None.
    func setMidiDestination(_ destination: MidiDestination?) {
        settings.midiOutUniqueID = destination?.uniqueID

        guard destination != midiOutDestination else { return }

        connectMidiOut(to: destination)
    }

    /// Mute Built-in Synth While Sending (default on): remembered, and in force at once.
    var midiOutMutesSynth: Bool {
        get { settings.midiOutMutesSynth }
        set {
            settings.midiOutMutesSynth = newValue
            applyMidiOutSynthMute()
        }
    }

    /// Points the output at `destination`: the old one is silenced first (``MidiOutput``'s own
    /// order), the new one gets the channels' programs and controllers.
    private func connectMidiOut(to destination: MidiDestination?) {
        let output = engine.synthBank.midiOut

        output.setDestination(destination)
        midiOutDestination = output.destination

        refreshMidiRoutes()
        applyMidiOutSynthMute()
    }

    /// The synth is silent only while something is being sent and the toggle is on.
    private func applyMidiOutSynthMute() {
        engine.synthBank.setSynthMutedForMidiOut(midiOutDestination != nil && settings.midiOutMutesSynth)
    }

    // MARK: - Routes

    /// The take's channel map, as the export assigns it in the chosen overflow mode, and the
    /// mixer's mutes, solos, faders and pans, pushed to the output: after every change to the
    /// notes, the mix or the mode. A channel whose program or controllers moved is sent them.
    func refreshMidiRoutes() {
        let map = MidiChannelMap.assign(notes: notes, mode: settings.midiOverflowMode)

        engine.synthBank.midiOut.setRoutes(channels: map, mixer: mixer)
    }

    /// The mixer onto the synths and the MIDI output together: every fader, mute, solo and pan
    /// change goes through here.
    func applyMixer() {
        engine.synthBank.apply(mixer: mixer)
        refreshMidiRoutes()
    }
}
