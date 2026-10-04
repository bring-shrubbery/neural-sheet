import Foundation
import NeuralSheetCore
import Observation

/// The playback the view shows and changes (Audio Unit design §2, "UI"): the ORIG / MIDI mix and
/// the master, the strips' faders, mutes and solos, the plugin's own transport, and the host's as
/// the poll sees it. The work is the unit's (`NeuralSheetAudioUnit+Playback`); this keeps the
/// controls' values and hands them on. Main actor.
@Observable final class PluginPlayback {
    /// The crossfade, 0 the host's audio (or the take) alone, 1 the synth alone; the app's 0.5 to
    /// begin with.
    var mix: Double = 0.5 {
        didSet { applyMix() }
    }

    /// The master fader, −36…+6 dB, the app's 0 to begin with.
    var masterGainDb: Double = 0 {
        didSet { applyMix() }
    }

    /// The strips: one entry per instrument the notes name, with their settings.
    private(set) var mixer = InstrumentMixerState()

    /// What the synth plays.
    private(set) var notes: [NoteEvent] = []

    /// Bumped by every transport command, so the roll wakes its playhead.
    private(set) var transportRevision = 0

    /// The host transport's poll, once connected.
    private(set) var poll: PluginTransportPoll?

    /// Send MIDI to host: the transcription on the "NeuralSheet Plugin" source.
    private(set) var sendsMIDI = false

    /// The source could not be made the last time sending was turned on.
    private(set) var midiFailed = false

    @ObservationIgnored private weak var unit: NeuralSheetAudioUnit?

    func connect(_ unit: NeuralSheetAudioUnit) {
        self.unit = unit
        poll = unit.transportPoll
        applyMix()
        unit.setPlaybackNotes(notes, mixer: mixer)
    }

    // MARK: - What plays

    /// The notes from now on: the strips follow them (a strip's settings outlive a run that drops
    /// its instrument, as the app's mixer keeps them).
    func setNotes(_ notes: [NoteEvent]) {
        guard notes != self.notes else { return }

        self.notes = notes
        mixer.update(notes: notes, selectedPrograms: [])
        unit?.setPlaybackNotes(notes, mixer: mixer)
        applyMix()
    }

    /// The take the plugin's transport plays.
    func setTake(_ take: CapturedTake?) {
        unit?.setPlaybackTake(take)
        transportRevision += 1
    }

    // MARK: - Send MIDI to host

    func setSendsMIDI(_ sending: Bool) {
        guard let unit else { return }

        let made = unit.setSendsMIDI(sending)
        sendsMIDI = sending && made
        midiFailed = sending && !made
    }

    /// The app's setting for more instruments than channels.
    func setOverflowMode(_ mode: MidiOverflowMode) {
        unit?.setMidiOverflowMode(mode)
    }

    /// The mix, the master and the strips a host's saved state brought back, before its notes
    /// arrive (the strips keep their settings when the notes come), and Send MIDI to host.
    func restore(mix: Double, masterGainDb: Double, mixer settings: [Int: InstrumentChannelSettings], sendsMIDI: Bool) {
        self.mix = min(max(mix, 0), 1)
        self.masterGainDb = min(max(masterGainDb, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)
        mixer.settings = settings
        unit?.setPlaybackMixer(mixer)

        if sendsMIDI != self.sendsMIDI {
            setSendsMIDI(sendsMIDI)
        }
    }

    // MARK: - Strips

    func setGain(program: Int, db: Double) {
        mixer.setGain(program: program, db: db)
        unit?.setPlaybackMixer(mixer)
    }

    func toggleMute(program: Int) {
        mixer.setMuted(program: program, muted: !mixer.isMuted(program: program))
        unit?.setPlaybackMixer(mixer)
    }

    func toggleSolo(program: Int) {
        mixer.setSoloed(program: program, soloed: !mixer.isSoloed(program: program))
        unit?.setPlaybackMixer(mixer)
    }

    // MARK: - Transport

    /// Whether the plugin's own transport plays.
    var isPlaying: Bool { poll?.ownPlaying ?? false }

    /// Whether the host's transport moves; the plugin's own transport waits while it does.
    var hostPlaying: Bool { poll?.hostPlaying ?? false }

    /// Play / Pause of the plugin's own transport.
    func togglePlay() {
        guard let unit else { return }

        if isPlaying {
            unit.pause()
        } else {
            unit.play()
        }
        transportRevision += 1
    }

    func goToStart() {
        unit?.goToStart()
        transportRevision += 1
    }

    /// Seconds into the take for the roll's playhead, nil without a take.
    var playheadSeconds: Double? { unit?.playheadSeconds }

    // MARK: - Mix

    private func applyMix() {
        unit?.setMix(mix, masterGainDb: masterGainDb, hasNotes: !notes.isEmpty)
    }
}
