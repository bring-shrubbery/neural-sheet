import AudioToolbox
import Foundation
import NeuralSheetCore
import Synchronization
import os

/// A main-actor object held by the nonisolated unit: written and read on the main thread only,
/// handed across as a box.
nonisolated final class MainActorBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// The synth's ring for the host's format and the renderer filling it, and what it plays: the
/// unit's ``NeuralSheetAudioUnit/synthState``.
nonisolated struct SynthState {
    var ring: SynthRing?
    var renderer: SynthRenderer?
    var sampleRate: Double = 0
    var maxFrames = 0
    var notes: [NoteEvent] = []
    var mixer = InstrumentMixerState()
}

/// Playback on the unit (Audio Unit design §2, "UI" and "Playhead"): the synth's lifecycle with the
/// render resources, the notes and the mix it plays, the plugin's own transport, and the host
/// transport's poll. The render block's side is `+Render`.
///
/// The synth renderer is made only once there are notes and the host renders, so a unit without a
/// transcription -- every auval pass -- never starts an engine or a thread.
extension NeuralSheetAudioUnit {
    // MARK: - Render resources (the host's thread)

    /// A ring for the host's format; a renderer still running from before is stopped. Called by
    /// `allocateRenderResources` before the render block can see the ring.
    nonisolated func prepareSynth(sampleRate: Double, maxFrames: Int) -> SynthRing {
        let ring = SynthRenderer.makeRing(maxHostFrames: maxFrames)

        let previous = synthState.withLock { state -> SynthRenderer? in
            let previous = state.renderer
            state.renderer = nil
            state.ring = ring
            state.sampleRate = sampleRate
            state.maxFrames = maxFrames
            return previous
        }

        previous?.stop()
        return ring
    }

    /// The host renders from now on: the poll starts and, with notes, the synth.
    nonisolated func startPlayback() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.transportPoll.start()
                self.refreshSynth()
            }
        }
    }

    /// The host has stopped rendering: the synth stops and lets go of the ring, then the poll.
    nonisolated func stopPlayback() {
        let renderer = synthState.withLock { state -> SynthRenderer? in
            let renderer = state.renderer
            state.renderer = nil
            state.ring = nil
            return renderer
        }

        renderer?.stop()

        // Whatever the host's MIDI track was sent last is silenced.
        let box = pollBox
        let midi = midiOut
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                box.value?.stop()
                midi.panic()
            }
        }
    }

    /// The unit is going: the synth's thread is stopped and waited for, and the MIDI source
    /// silenced and disposed. No weak references here, in `deinit`; the poll's timer lets go of
    /// itself once the poll has gone.
    nonisolated func shutDownPlayback() {
        let renderer = synthState.withLock { state -> SynthRenderer? in
            let renderer = state.renderer
            state.renderer = nil
            return renderer
        }

        renderer?.stop()
        midiOut.shutDown()
    }

    // MARK: - Notes and mix (main actor)

    /// The notes the synth plays and the strips' state, from now on.
    @MainActor
    func setPlaybackNotes(_ notes: [NoteEvent], mixer: InstrumentMixerState) {
        let renderer = synthState.withLock { state -> SynthRenderer? in
            state.notes = notes
            state.mixer = mixer
            return state.renderer
        }

        midiOut.setNotes(notes, mixer: mixer)

        if let renderer {
            renderer.setMixer(mixer)
            renderer.setNotes(notes)
        } else {
            refreshSynth()
        }
    }

    /// The strips' faders, mutes and solos.
    @MainActor
    func setPlaybackMixer(_ mixer: InstrumentMixerState) {
        let renderer = synthState.withLock { state -> SynthRenderer? in
            state.mixer = mixer
            return state.renderer
        }

        renderer?.setMixer(mixer)
        midiOut.setMixer(mixer)
    }

    // MARK: - Send MIDI to host (main actor)

    /// Sends the transcription on the "NeuralSheet Plugin" source from now on, or stops. False
    /// when the source could not be made.
    @MainActor @discardableResult
    func setSendsMIDI(_ sending: Bool) -> Bool {
        midiOut.setSending(sending)
    }

    @MainActor
    func setMidiOverflowMode(_ mode: MidiOverflowMode) {
        midiOut.setOverflowMode(mode)
    }

    /// The crossfade, the master and the notes' presence, as ``MixLaw`` resolves them.
    @MainActor
    func setMix(_ mix: Double, masterGainDb: Double, hasNotes: Bool) {
        transport.setGains(MixLaw.resolve(mix: mix, masterGainDb: masterGainDb, muted: false, stereoSplit: false,
                                          hasNotes: hasNotes))
    }

    /// Makes and starts the renderer once the host renders and there are notes. Main actor: the
    /// scheduler's note list is the main thread's to swap.
    @MainActor
    private func refreshSynth() {
        synthState.withLock { state in
            guard state.renderer == nil, let ring = state.ring, !state.notes.isEmpty else { return }

            guard let renderer = SynthRenderer(ring: ring, sampleRate: state.sampleRate,
                                               maxHostFrames: state.maxFrames)
            else { return }

            renderer.setMixer(state.mixer)
            renderer.setNotes(state.notes)
            renderer.start()
            state.renderer = renderer

            let rate = Int(state.sampleRate)
            let count = state.notes.count
            PluginLog.logger.info("synth: started at \(rate) Hz, \(count) notes")
        }
    }

    // MARK: - The take and the plugin's own transport (main actor)

    /// The take the plugin's transport plays, at the host's rate, with its start on the host's
    /// clock for the playhead that follows the host.
    @MainActor
    func setPlaybackTake(_ take: CapturedTake?) {
        guard let take else {
            transport.setTake(nil, startSampleTime: nil)
            return
        }

        let rate = synthState.withLock { $0.sampleRate }
        // A take captured at another rate plays at the host's, and its start on the host's clock
        // means nothing any more.
        let source = rate > 0 && rate != take.sampleRate ? take.source.resampled(to: rate) : take.source
        transport.setTake(source, startSampleTime: rate > 0 && rate != take.sampleRate ? nil : take.startSampleTime)
    }

    @MainActor
    func play() {
        transport.play()
        transportPoll.refreshOwn()
    }

    @MainActor
    func pause() {
        transport.pause()
        transportPoll.refreshOwn()
        midiOut.panic()
    }

    /// Go to start.
    @MainActor
    func goToStart() {
        transport.seek(toFrame: 0)
        midiOut.panic()
    }

    /// The plugin's own transport to `seconds` into the take.
    @MainActor
    func seek(toSeconds seconds: Double) {
        let rate = transport.take?.deviceRate ?? 0
        transport.seek(toFrame: Int((seconds * rate).rounded()))
        midiOut.panic()
    }

    /// The roll's playhead, in seconds into the take: the host's position while it plays, the
    /// plugin's transport otherwise; nil without a take.
    @MainActor
    var playheadSeconds: Double? {
        guard let rate = transport.take?.deviceRate, rate > 0 else { return nil }
        return Double(transport.playheadFrame) / rate
    }

    // MARK: - The poll

    /// The host transport's poll, made on first use.
    @MainActor
    var transportPoll: PluginTransportPoll {
        if let poll = pollBox.value { return poll }

        let poll = PluginTransportPoll(transport: transport) { [weak self] in
            self?.hostState() ?? PluginTransportPoll.HostState()
        }
        // The host starting or stopping, or the take's end, leaves nothing sounding on the
        // host's MIDI track.
        let midi = midiOut
        poll.onHostStart = { midi.panic() }
        poll.onHostStop = { midi.panic() }
        poll.onOwnStop = { midi.panic() }
        pollBox.value = poll
        return poll
    }

    /// The host's transport and tempo through its blocks. Main thread only, from the poll.
    @MainActor
    private func hostState() -> PluginTransportPoll.HostState {
        var state = PluginTransportPoll.HostState(playing: hostTransportIsMoving())

        if let block = musicalContextBlock {
            var tempo: Double = 0
            if block(&tempo, nil, nil, nil, nil, nil), tempo > 0 {
                state.tempo = tempo
            }
        }

        return state
    }
}
