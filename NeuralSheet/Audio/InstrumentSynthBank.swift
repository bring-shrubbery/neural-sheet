import AVFoundation
import AudioToolbox
import Foundation
import NeuralSheetCore
import Synchronization

/// One transcribed instrument: its synth, the sub-mix input it feeds, and the meter after it.
///
/// Reached from the main thread and from the tap thread, both under ``InstrumentSynthBank``'s lock.
/// The render thread never sees it — it only reads the cached scheduling block out of the bank's
/// table.
private nonisolated final class SynthInstrument: @unchecked Sendable {
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

/// The synth side of the graph: one Apple MIDI synth per transcribed instrument, a sub-mix carrying
/// the per-instrument faders, and the `scheduleMIDIEventBlock` calls that put the scheduler's events
/// on the timeline one cycle ahead (spec §4.3, inventory §5.2).
///
/// ```
/// synth[program] ─▶ (its own input bus) subMixer ─▶ mixTarget
/// ```
///
/// One synth per instrument rather than one synth on 16 channels: a transcription names 35
/// instruments, and a per-instrument fader, mute, solo and meter each want a node of their own.
///
/// Threading. ``schedule(from:to:renderTime:frameCount:sampleRate:)`` is the render thread's; it
/// allocates nothing, locks nothing and looks nothing up — the scheduling blocks live in a fixed
/// table indexed by program, filled at ``ensureInstrument(program:)`` time, so the render path never
/// touches a dictionary, a string or an Objective-C property. Everything else is the main thread's,
/// except the meter taps, which run on AVAudioEngine's tap thread and share ``lock`` with it. The
/// lock is never taken on the render thread, which is what makes a plain lock the right tool here.
nonisolated final class InstrumentSynthBank: @unchecked Sendable {
    let scheduler = NoteScheduler()

    /// Programs 0…128, the last being `NoteEvent.drumProgram`.
    private static let programCount = NoteEvent.drumProgram + 1

    /// GM2 melodic bank on channel 1 and GM2 percussion on channel 10 — zero-based here, which is
    /// what the wire format uses.
    private static let melodicChannel: UInt8 = 0
    private static let drumChannel: UInt8 = 9
    private static let melodicBankMSB: UInt8 = 121
    private static let drumBankMSB: UInt8 = 120

    /// Fixed, as the spec has it: the model's amplitude drives the fader, not the note.
    private static let velocity: UInt8 = 100

    private static let noteOnStatus: UInt8 = 0x90
    private static let noteOffStatus: UInt8 = 0x80
    private static let allNotesOffController: UInt8 = 123

    private static let meterTapFrames: AVAudioFrameCount = 512

    /// Bigger than the tap asks for: a tap block may hand over more than its buffer size.
    private static let meterScratchFrames = 8192

    /// The fader's silent end, the app's one gain floor.
    private static let minGainDb = InstrumentMixerState.minGainDb

    /// How long a synth dropped by ``reset()`` is kept alive and in the graph — orders of magnitude
    /// more than one render cycle, which is all the render block needs.
    private static let retirementSeconds = 0.5

    private let engine: AVAudioEngine
    private let mixTarget: AVAudioMixerNode

    /// Every synth's fader lands on an input of this, and ``synthGain`` is its output volume, so the
    /// crossfade is one number on one node rather than a multiply on each instrument.
    private let subMixer = AVAudioMixerNode()

    // MARK: - The render thread's

    /// Pre-reserved to ``NoteScheduler/reservedEventCapacity`` in `init`, which is the most one
    /// block can produce, so the render thread's only array work is writing into storage that
    /// already exists.
    private var events: [SynthEvent] = []

    /// The three bytes of the message being scheduled. One buffer, rewritten per event.
    private let midiBytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 3)

    /// `scheduleMIDIEventBlock` per program, so the render path is an indexed load rather than a
    /// dictionary lookup and an Objective-C property call. Written only from the main thread, and
    /// only once the node behind it is attached and connected.
    private let blocks: UnsafeMutableBufferPointer<AUScheduleMIDIEventBlock?>

    private let frameCounter = Atomic<UInt64>(0)

    // MARK: - The main thread's, shared with the tap thread

    /// Guards ``instruments`` and everything reachable through it.
    private let lock = NSLock()

    private var instruments: [Int: SynthInstrument] = [:]

    /// Synths ``reset()`` has taken out of the table but not yet out of the graph, held until the
    /// render block cannot still be inside one of their scheduling blocks.
    ///
    /// Main thread only. Clearing a table entry stops *new* loads; a cycle that already has the
    /// block in hand is still going to call it, so neither the block nor the audio unit behind it
    /// may go until that cycle cannot be running any more.
    private var retiredInstruments: [SynthInstrument] = []

    /// The last mix applied, so a synth created after it starts at the gain its instrument already
    /// has rather than at unity. Main thread.
    private var appliedMixer = InstrumentMixerState()

    /// The synth side of the equal-power crossfade, `sin(mix · π/2)`. Written from the main thread;
    /// it is the sub-mix's output volume, so it applies to every instrument at once.
    var synthGain: Float = 0 {
        didSet { subMixer.outputVolume = synthGain }
    }

    /// How many frames the render block has asked this bank to schedule for, ever.
    ///
    /// It lives here rather than on ``PlaybackEngine`` because ``schedule(from:to:renderTime:frameCount:sampleRate:)``
    /// is what the render block calls unconditionally, playing or not — exactly the "is the audio
    /// thread still running" signal the meters' staleness rule needs (§2.5). A counter that has not
    /// moved for `max(0.5 s, 2 × block)` means every meter should be walked down rather than left
    /// holding its last level.
    var renderedFrames: UInt64 { frameCounter.load(ordering: .relaxed) }

    init(engine: AVAudioEngine, mixTarget: AVAudioMixerNode) {
        self.engine = engine
        self.mixTarget = mixTarget

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

        guard !exists else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // Nothing here can conjure a synth that the system does not have; leaving the instrument out
        // is silence on one program rather than a crash for the whole transcription.
        guard AudioComponentFindNext(nil, &description) != nil else { return }

        let node = AVAudioUnitMIDIInstrument(audioComponentDescription: description)
        let bus = subMixer.nextAvailableInputBus

        engine.attach(node)
        // At the engine's own rate, never the synth's default: the events are scheduled against the
        // source node's sample time, and an AU rendering at 44.1 kHz under a 48 kHz engine counts
        // its own samples 8 % slower, so every scheduled note lands later and later -- silence that
        // grows with the app's uptime.
        engine.connect(node, to: subMixer, fromBus: 0, toBus: bus, format: renderFormat)

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

        node.installTap(onBus: 0, bufferSize: InstrumentSynthBank.meterTapFrames, format: nil) {
            [weak self] buffer, _ in
            self?.pushMeter(buffer, for: program)
        }

        lock.lock()
        instruments[program] = instrument
        lock.unlock()

        // Last, so the render thread only ever sees a block whose node is already in the graph.
        blocks[program] = instrument.scheduleBlock
    }

    /// The rate every synth renders at: the engine's, so the synths' sample timelines are the
    /// source node's, which is what the scheduled events are timed against.
    private var renderRate: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate

        return rate > 0 ? rate : 48000
    }

    private var renderFormat: AVAudioFormat? {
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

            // The AU's channel state need not survive being reconfigured; see ``allNotesOff()``.
            sendProgramChange(to: instrument.node, program: instrument.program)
        }
    }

    /// Drops every synth and every sounding note. Main thread.
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

        retire(dropped)
    }

    /// Bank select then program change, on the channel this instrument's notes arrive on.
    private func sendProgramChange(to node: AVAudioUnitMIDIInstrument, program: Int) {
        if program == NoteEvent.drumProgram {
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
        instrument.node.removeTap(onBus: 0)
        engine.disconnectNodeOutput(instrument.node)
        engine.detach(instrument.node)
    }

    // MARK: - Render thread

    /// Schedules everything in `[t0, t1)` one buffer ahead of `renderTime`.
    ///
    /// One buffer ahead because the synths render in the same cycle as the source node and their
    /// order within it is not defined; ``PlaybackEngine`` delays its own source read by the same
    /// buffer, which is what keeps the two sample-aligned.
    func schedule(
        from t0: Double, to t1: Double, renderTime: AudioTimeStamp, frameCount: Int,
        sampleRate: Double
    ) {
        frameCounter.wrappingAdd(UInt64(Swift.max(frameCount, 0)), ordering: .relaxed)

        scheduler.collect(from: t0, to: t1, sampleRate: sampleRate, into: &events)

        guard !events.isEmpty, let bytes = midiBytes.baseAddress else { return }

        // `AUEventSampleTimeImmediate` takes a buffer offset too, so a timestamp without a usable
        // sample time still places the events inside the block rather than losing their order.
        let sampleTime = renderTime.mSampleTime
        let hasSampleTime =
            renderTime.mFlags.contains(.sampleTimeValid) && sampleTime.isFinite
            && abs(sampleTime) < 4e15
        let base =
            hasSampleTime
            ? AUEventSampleTime(sampleTime) + AUEventSampleTime(frameCount)
            : AUEventSampleTime(AUEventSampleTimeImmediate)

        events.withUnsafeBufferPointer { collected in
            for event in collected {
                let isDrum = event.program == NoteEvent.drumProgram

                // Drum note-offs are never sent: a GM kit is one-shot, and a note-off 10 ms into a
                // hit would choke every cymbal. A seek or a stop silences them with CC 123 instead.
                if isDrum, !event.isOn { continue }

                guard event.program >= 0, event.program < InstrumentSynthBank.programCount,
                    let block = blocks[event.program]
                else { continue }

                let channel =
                    isDrum ? InstrumentSynthBank.drumChannel : InstrumentSynthBank.melodicChannel

                bytes[0] =
                    (event.isOn
                        ? InstrumentSynthBank.noteOnStatus : InstrumentSynthBank.noteOffStatus)
                    | channel
                bytes[1] = UInt8(Swift.min(Swift.max(event.pitch, 0), 127))
                bytes[2] = event.isOn ? InstrumentSynthBank.velocity : 0

                block(base + AUEventSampleTime(event.sampleOffset), 0, 3, UnsafePointer(bytes))
            }
        }
    }

    // MARK: - Mix

    /// CC 123 on both channels to every synth, for a stop or a seek — including the drums, whose
    /// one-shot hits ignore the scheduler's note-offs.
    ///
    /// Any thread but the render thread: it takes the bank's lock. It also re-sends each synth's bank
    /// and program, because an AU's channel state does not necessarily survive the engine being
    /// reconfigured under it (a device change rebuilds the graph), and an instrument that had
    /// quietly reverted to program 0 would play the rest of the session as a piano.
    func allNotesOff() {
        lock.lock()
        let current = Array(instruments.values)
        lock.unlock()

        for instrument in current {
            sendAllNotesOff(to: instrument.node)
            sendProgramChange(to: instrument.node, program: instrument.program)
        }
    }

    /// CC 123 on both the melodic and the percussion channel.
    private func sendAllNotesOff(to node: AVAudioUnitMIDIInstrument) {
        node.sendController(
            InstrumentSynthBank.allNotesOffController,
            withValue: 0,
            onChannel: InstrumentSynthBank.melodicChannel)
        node.sendController(
            InstrumentSynthBank.allNotesOffController,
            withValue: 0,
            onChannel: InstrumentSynthBank.drumChannel)
    }

    /// Pushes the fader, mute and solo state onto the sub-mix inputs. Main thread.
    ///
    /// Solo is derived here rather than stored as "the others are muted": `isAudible` is the one
    /// place that decision lives, and the piano roll dims its notes by the same answer.
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
        }
    }

    /// One instrument's mixer-input gain: the fader in linear terms, silenced outright when the
    /// fader is at its floor or the instrument is not currently heard.
    private static func gain(for program: Int, in mixer: InstrumentMixerState) -> Float {
        let db = mixer.gainDb(program: program)
        // −36 dB is the fader's silent end, not a very quiet one.
        let linear = db <= InstrumentSynthBank.minGainDb ? 0 : pow(10.0, db / 20.0)

        return Float(linear * (mixer.isAudible(program: program) ? 1 : 0))
    }

    /// One instrument's post-fader level over the meter window.
    func levelDb(program: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }

        return instruments[program]?.meter.decibels ?? RmsMeter.floorDb
    }

    /// Tap thread. Folds one synth's output to mono, scales it by the gain its mixer input is
    /// carrying — the tap is ahead of that input, so this is what makes the meter post-fader — and
    /// pushes it into that instrument's window.
    private func pushMeter(_ buffer: AVAudioPCMBuffer, for program: Int) {
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
