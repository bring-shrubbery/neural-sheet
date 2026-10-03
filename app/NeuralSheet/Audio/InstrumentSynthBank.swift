import AVFoundation
import AudioToolbox
import Foundation
import NeuralSheetCore
import Synchronization

/// The synth side of the graph: one Apple MIDI synth per transcribed instrument, a sub-mix carrying
/// the per-instrument faders, and the `scheduleMIDIEventBlock` calls that put the scheduler's events
/// on the timeline one cycle ahead (spec §4.3, inventory §5.2). Beside them, outside the sub-mix,
/// the click's own synth fed by a second scheduler (click design §2).
///
/// ```
/// synth[program] ─▶ (its own input bus) subMixer ─▶ mixTarget
/// click synth ─────────────────────────────────────▶ mixTarget
/// ```
///
/// One synth per instrument rather than one synth on 16 channels: a transcription names 35
/// instruments, and a per-instrument fader, mute, solo, pan and meter each want a node of their
/// own.
///
/// Threading. ``schedule(from:to:renderTime:frameCount:sampleRate:outputRate:)`` is the render
/// thread's; it allocates nothing, locks nothing and looks nothing up — the scheduling blocks live
/// in a fixed table indexed by program, filled at ``ensureInstrument(program:)`` time, so the
/// render path never touches a dictionary, a string or an Objective-C property. Everything else is
/// the main thread's, except the meter taps, which run on AVAudioEngine's tap thread and share
/// ``lock`` with it. The lock is never taken on the render thread, which is what makes a plain lock
/// the right tool here.
///
/// The render path, the mix, the audition, the sound bank, the click and the MIDI output live in
/// `InstrumentSynthBank+Render.swift`, `+Mix.swift`, `+Audition.swift`, `+SoundBank.swift`,
/// `+Click.swift` and `+MidiOut.swift`; the members they share are internal rather than private
/// for that reason only.
nonisolated final class InstrumentSynthBank: @unchecked Sendable {
    let scheduler = NoteScheduler()

    /// Programs 0…129: the instruments, `NoteEvent.drumProgram` and the click
    /// (`ClickTrack.program`), which gets a slot in the table so the render path needs no second
    /// lookup for it (click design §3).
    static let programCount = ClickTrack.program + 1

    /// GM2 melodic bank on channel 1 and GM2 percussion on channel 10 — zero-based here, which is
    /// what the wire format uses.
    static let melodicChannel: UInt8 = 0
    static let drumChannel: UInt8 = 9
    static let melodicBankMSB: UInt8 = 121
    static let drumBankMSB: UInt8 = 120

    // Velocity is per note now (`SynthEvent.velocity`); the design's fixed 100 is what every
    // model note still carries, so nothing sounds different until one is edited.

    static let noteOnStatus: UInt8 = 0x90
    static let noteOffStatus: UInt8 = 0x80
    static let allNotesOffController: UInt8 = 123

    private static let meterTapFrames: AVAudioFrameCount = 512

    /// Bigger than the tap asks for: a tap block may hand over more than its buffer size.
    static let meterScratchFrames = 8192

    /// The fader's silent end, the app's one gain floor.
    static let minGainDb = InstrumentMixerState.minGainDb

    /// How long a synth dropped by ``reset()`` is kept alive and in the graph — orders of magnitude
    /// more than one render cycle, which is all the render block needs.
    private static let retirementSeconds = 0.5

    let engine: AVAudioEngine
    let mixTarget: AVAudioMixerNode

    /// Every synth's fader lands on an input of this, and ``synthGain`` is its output volume, so the
    /// crossfade is one number on one node rather than a multiply on each instrument.
    let subMixer = AVAudioMixerNode()

    // MARK: - The render thread's

    /// Pre-reserved to ``NoteScheduler/reservedEventCapacity`` in `init`, which is the most one
    /// block can produce, so the render thread's only array work is writing into storage that
    /// already exists.
    var events: [SynthEvent] = []

    /// The three bytes of the message being scheduled. One buffer, rewritten per event.
    let midiBytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 3)

    /// `scheduleMIDIEventBlock` per program, so the render path is an indexed load rather than a
    /// dictionary lookup and an Objective-C property call. Written only from the main thread, and
    /// only once the node behind it is attached and connected.
    let blocks: UnsafeMutableBufferPointer<AUScheduleMIDIEventBlock?>

    let frameCounter = Atomic<UInt64>(0)

    /// The click's scheduler, clock and switches (click design §2–§3), everything of it the
    /// render thread reads.
    let click = ClickRenderState()

    /// The live MIDI output (MIDI out design §2): the render thread pushes the instruments' events
    /// into its ring beside the synths, never the click's (`+MidiOut.swift`). Unconnected in an
    /// offline bank, so an export never plays into the DAW.
    let midiOut: MidiOutput

    /// False for the offline renderer's bank (audio export design §2): no MIDI output, no click
    /// synth, no meter taps -- nothing of it reaches beyond its own engine.
    let isLive: Bool

    // MARK: - The main thread's, shared with the tap thread

    /// Guards ``instruments`` and everything reachable through it.
    let lock = NSLock()

    var instruments: [Int: SynthInstrument] = [:]

    /// Synths ``reset()`` has taken out of the table but not yet out of the graph, held until the
    /// render block cannot still be inside one of their scheduling blocks.
    ///
    /// Main thread only. Clearing a table entry stops *new* loads; a cycle that already has the
    /// block in hand is still going to call it, so neither the block nor the audio unit behind it
    /// may go until that cycle cannot be running any more.
    private var retiredInstruments: [SynthInstrument] = []

    /// The last mix applied, so a synth created after it starts at the gain and pan its instrument
    /// already has rather than at unity and centre. Main thread.
    var appliedMixer = InstrumentMixerState()

    /// The click's synth, outside the sub-mix and never reset (`+Click.swift`). Main thread.
    var clickInstrument: SynthInstrument?

    /// The bank every synth loads, or nil for the system's (`+SoundBank.swift`). Main thread.
    var soundBankURL: URL?

    /// The note the editor is sounding on its own, so the next audition can end it rather than
    /// let its note-off land on a new note at the same pitch. A drum hit is one-shot and gets no
    /// note-off, but is kept here for as long as it is heard, for the lift below. Main thread.
    var audition: (program: Int, pitch: UInt8, isDrum: Bool, generation: Int)?
    var auditionGeneration = 0

    /// The synth side of the equal-power crossfade, `sin(mix · π/2)`. Written from the main thread;
    /// it is the sub-mix's output volume, so it applies to every instrument at once.
    var synthGain: Float = 0 {
        didSet { applySubMixVolume() }
    }

    /// While an audition sounds the sub-mix is at unity whatever the crossfade says, so a note the
    /// editor clicks, draws or moves is heard even with the mix fully on the original. The
    /// transport is stopped whenever there is an audition (``PlaybackEngine/play()`` ends one
    /// first), so nothing of the take is under it to be balanced against. Main thread.
    var auditionLifted = false {
        didSet { applySubMixVolume() }
    }

    /// While the MIDI output is sending and Mute Built-in Synth While Sending is on, the sub-mix
    /// is silent whatever the crossfade or an audition says, so the DAW's instruments are heard
    /// instead (MIDI out design §2). The click and the original are not on the sub-mix. Main
    /// thread (`+MidiOut.swift`).
    var synthMutedForMidiOut = false {
        didSet { applySubMixVolume() }
    }

    private func applySubMixVolume() {
        subMixer.outputVolume = synthMutedForMidiOut ? 0 : (auditionLifted ? 1 : synthGain)
    }

    /// How many frames the render block has asked this bank to schedule for, ever.
    ///
    /// It lives here rather than on ``PlaybackEngine`` because the schedule call is what the render
    /// block makes unconditionally, playing or not — exactly the "is the audio thread still
    /// running" signal the meters' staleness rule needs (§2.5). A counter that has not moved for
    /// `max(0.5 s, 2 × block)` means every meter should be walked down rather than left holding its
    /// last level.
    var renderedFrames: UInt64 { frameCounter.load(ordering: .relaxed) }

    /// A bank on `engine`, its sub-mix into `mixTarget`. Any number may exist, each on its own
    /// engine: nothing here is static but constants. `live: false` is the offline renderer's.
    init(engine: AVAudioEngine, mixTarget: AVAudioMixerNode, live: Bool = true) {
        self.engine = engine
        self.mixTarget = mixTarget
        isLive = live
        midiOut = MidiOutput(connected: live)

        blocks = UnsafeMutableBufferPointer<AUScheduleMIDIEventBlock?>.allocate(
            capacity: InstrumentSynthBank.programCount)
        blocks.initialize(repeating: nil)

        midiBytes.initialize(repeating: 0)

        events.reserveCapacity(NoteScheduler.reservedEventCapacity)

        engine.attach(subMixer)
        // At the engine's rate from the first connection, not the mixer's 44.1 kHz default: `nil`
        // here left the sub-mix converting under a 48 kHz engine until the first device rebuild
        // came through ``reconnectForCurrentRate()``.
        engine.connect(subMixer, to: mixTarget, format: renderFormat)
        subMixer.outputVolume = synthGain

        // The click is never rendered offline (issue #22, out of scope).
        if live { ensureClickInstrument() }
    }

    deinit {
        // The table first, then the nodes behind it — the same order ``reset()`` uses, for the same
        // reason. There is no grace period to wait out here and nowhere to wait it out from: the
        // bank is owned by ``PlaybackEngine``, whose own `deinit` stops the engine before releasing
        // it, so the render thread has already gone by the time this runs.
        blocks.update(repeating: nil)

        for instrument in Array(instruments.values) + retiredInstruments {
            dispose(instrument)
        }

        // The click's synth has no meter tap to take off.
        if let click = clickInstrument {
            engine.disconnectNodeOutput(click.node)
            engine.detach(click.node)
        }

        blocks.deinitialize()
        blocks.deallocate()

        midiBytes.deallocate()
    }

    // MARK: - Instruments

    /// Creates the synth for `program` if it has none yet. Main thread.
    ///
    /// The bank select and program change go out here, once: the AU keeps them on its channel, and
    /// re-sending them per note would be three more messages on the render thread for nothing.
    func ensureInstrument(program: Int) {
        guard (0...NoteEvent.drumProgram).contains(program) else { return }

        lock.lock()
        let exists = instruments[program] != nil
        lock.unlock()

        guard !exists, let node = makeSynthNode() else { return }

        let bus = subMixer.nextAvailableInputBus

        engine.attach(node)
        // At the engine's own rate, never the synth's default: the events are scheduled against the
        // source node's sample time, and an AU rendering at 44.1 kHz under a 48 kHz engine counts
        // its own samples 8 % slower, so every scheduled note lands later and later -- silence that
        // grows with the app's uptime.
        engine.connect(node, to: subMixer, fromBus: 0, toBus: bus, format: renderFormat)

        // The bank before the program change, which picks its preset from it (click design §2).
        loadCurrentSoundBank(into: node)
        sendProgramChange(to: node, program: program)

        let instrument = SynthInstrument(
            program: program,
            node: node,
            bus: bus,
            sampleRate: renderRate,
            scratchFrames: InstrumentSynthBank.meterScratchFrames
        )

        // From the mix that is already in force, not from unity: a program the user had muted before
        // its synth existed must not get one audible block on the way in.
        instrument.gain = InstrumentSynthBank.gain(for: program, in: appliedMixer)
        instrument.scheduleBlock = node.auAudioUnit.scheduleMIDIEventBlock
        node.volume = instrument.gain
        node.pan = Float(appliedMixer.pan(program: program))

        // No meters offline: nothing shows them, and a tap is one more thing on the render path.
        if isLive {
            node.installTap(onBus: 0, bufferSize: InstrumentSynthBank.meterTapFrames, format: nil) {
                [weak self] buffer, _ in
                self?.pushMeter(buffer, for: program)
            }
        }

        lock.lock()
        instruments[program] = instrument
        lock.unlock()

        // Last, so the render thread only ever sees a block whose node is already in the graph.
        blocks[program] = instrument.scheduleBlock
    }

    /// A fresh DLS synth, or nil when the system has none: nothing here can conjure one, and
    /// leaving an instrument out is silence on one program rather than a crash.
    func makeSynthNode() -> AVAudioUnitMIDIInstrument? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard AudioComponentFindNext(nil, &description) != nil else { return nil }

        return AVAudioUnitMIDIInstrument(audioComponentDescription: description)
    }

    /// The rate every synth renders at: the engine's, so the synths' sample timelines are the
    /// source node's, which is what the scheduled events are timed against.
    var renderRate: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate

        return rate > 0 ? rate : 48000
    }

    var renderFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: renderRate, channels: 2)
    }

    /// Re-links every synth at the engine's current rate. Main thread, with the engine stopped:
    /// after the graph has been rebuilt for new hardware, whose rate the synths were not
    /// connected for.
    func reconnectForCurrentRate() {
        lock.lock()
        let current = Array(instruments.values)
        lock.unlock()

        let rate = renderRate
        let format = renderFormat

        engine.disconnectNodeOutput(subMixer)
        engine.connect(subMixer, to: mixTarget, format: format)

        for instrument in current {
            engine.disconnectNodeOutput(instrument.node)
            engine.connect(instrument.node, to: subMixer, fromBus: 0, toBus: instrument.bus, format: format)

            lock.lock()
            instrument.meter = RmsMeter(sampleRate: rate)
            lock.unlock()

            // A new connection point starts at unity and centre; the mix is put back on it.
            instrument.node.volume = instrument.gain
            instrument.node.pan = Float(appliedMixer.pan(program: instrument.program))

            // The AU's channel state need not survive being reconfigured; see ``allNotesOff()``.
            sendProgramChange(to: instrument.node, program: instrument.program)
        }

        reconnectClickForCurrentRate()
    }

    /// Drops every synth and every sounding note. Main thread. The click's synth stays: it is not
    /// the transcription's.
    func reset() {
        lock.lock()
        let dropped = Array(instruments.values)
        instruments.removeAll()
        lock.unlock()

        // The table first: it is the only thing the render thread reads. Clearing an entry stops new
        // loads of that block, which is all ``reset()`` can do synchronously — the node, the block
        // and the audio unit behind it all go together, later.
        for instrument in dropped {
            blocks[instrument.program] = nil
        }

        // They are about to stop being reachable, so anything sounding would ring on until the
        // retirement timer finally takes the node out.
        for instrument in dropped {
            sendAllNotesOff(to: instrument.node)
        }

        clearAudition()
        retire(dropped)
    }

    /// Holds dropped synths — node, scheduling block and all — until any render block that saw one
    /// has long since returned, and only then takes them out of the graph.
    ///
    /// Tearing the node down inside ``reset()`` would free the audio unit under a render cycle that
    /// had already loaded its block, which is a call into disposed memory rather than a missed note.
    private func retire(_ dropped: [SynthInstrument]) {
        guard !dropped.isEmpty else { return }

        retiredInstruments.append(contentsOf: dropped)

        DispatchQueue.main.asyncAfter(deadline: .now() + InstrumentSynthBank.retirementSeconds) {
            [weak self] in
            // No `self` means the bank has gone, and with it the engine — `dropped` is released here
            // and there is no graph left to take the nodes out of.
            guard let self else { return }

            for instrument in dropped {
                self.dispose(instrument)

                if let index = self.retiredInstruments.firstIndex(where: { $0 === instrument }) {
                    self.retiredInstruments.remove(at: index)
                }
            }
        }
    }

    /// Takes one synth out of the graph. Main thread, and only once nothing can still be scheduling
    /// into it.
    private func dispose(_ instrument: SynthInstrument) {
        if isLive { instrument.node.removeTap(onBus: 0) }
        engine.disconnectNodeOutput(instrument.node)
        engine.detach(instrument.node)
    }
}
