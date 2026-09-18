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

    /// How long a scheduling block dropped by ``reset()`` is kept alive — orders of magnitude more
    /// than one render cycle, which is all the block needs.
    private static let retirementSeconds = 0.5

    private let engine: AVAudioEngine
    private let mixTarget: AVAudioMixerNode

    /// Every synth's fader lands on an input of this, and ``synthGain`` is its output volume, so the
    /// crossfade is one number on one node rather than a multiply on each instrument.
    private let subMixer = AVAudioMixerNode()

    // MARK: - The render thread's

    /// Pre-reserved to ``NoteScheduler/eventCapacity`` in `init` and never grown past it, so the
    /// render thread's only array work is writing into storage that already exists.
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

    /// Blocks ``reset()`` has taken out of the table, held until the render block cannot be inside
    /// one.
    private var retiredBlocks: [AUScheduleMIDIEventBlock] = []

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

        events.reserveCapacity(NoteScheduler.eventCapacity)

        engine.attach(subMixer)
        engine.connect(subMixer, to: mixTarget, format: nil)
        subMixer.outputVolume = synthGain
    }

    deinit {
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
        engine.connect(node, to: subMixer, fromBus: 0, toBus: bus, format: nil)

        sendProgramChange(to: node, program: program)

        let nodeRate = node.outputFormat(forBus: 0).sampleRate
        let engineRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let instrument = SynthInstrument(
            program: program,
            node: node,
            bus: bus,
            sampleRate: nodeRate > 0 ? nodeRate : (engineRate > 0 ? engineRate : 48000),
            scratchFrames: InstrumentSynthBank.meterScratchFrames
        )

        node.volume = instrument.gain

        node.installTap(onBus: 0, bufferSize: InstrumentSynthBank.meterTapFrames, format: nil) {
            [weak self] buffer, _ in
            self?.pushMeter(buffer, for: program)
        }

        lock.lock()
        instruments[program] = instrument
        lock.unlock()

        // Last, so the render thread only ever sees a block whose node is already in the graph.
        blocks[program] = node.auAudioUnit.scheduleMIDIEventBlock
    }

    /// Drops every synth and every sounding note. Main thread.
    func reset() {
        lock.lock()
        let dropped = instruments
        instruments.removeAll()
        lock.unlock()

        // The table first: it is the only thing the render thread reads, and a block taken out of it
        // is still held for a grace period rather than freed under a block that is mid-call.
        for program in dropped.keys {
            if let block = blocks[program] {
                retire(block)
                blocks[program] = nil
            }
        }

        for instrument in dropped.values {
            instrument.node.removeTap(onBus: 0)
            engine.disconnectNodeOutput(instrument.node)
            engine.detach(instrument.node)
        }
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

    /// Holds a dropped scheduling block until any render block that saw it has long since returned.
    private func retire(_ block: @escaping AUScheduleMIDIEventBlock) {
        retiredBlocks.append(block)

        DispatchQueue.main.asyncAfter(deadline: .now() + InstrumentSynthBank.retirementSeconds) {
            [weak self] in
            guard let self, !self.retiredBlocks.isEmpty else { return }
            self.retiredBlocks.removeFirst()
        }
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
            instrument.node.sendController(
                InstrumentSynthBank.allNotesOffController,
                withValue: 0,
                onChannel: InstrumentSynthBank.melodicChannel)
            instrument.node.sendController(
                InstrumentSynthBank.allNotesOffController,
                withValue: 0,
                onChannel: InstrumentSynthBank.drumChannel)

            sendProgramChange(to: instrument.node, program: instrument.program)
        }
    }

    /// Pushes the fader, mute and solo state onto the sub-mix inputs. Main thread.
    ///
    /// Solo is derived here rather than stored as "the others are muted": `isAudible` is the one
    /// place that decision lives, and the piano roll dims its notes by the same answer.
    func apply(mixer: InstrumentMixerState) {
        lock.lock()
        defer { lock.unlock() }

        for instrument in instruments.values {
            let db = mixer.gainDb(program: instrument.program)
            // −36 dB is the fader's silent end, not a very quiet one.
            let linear = db <= InstrumentSynthBank.minGainDb ? 0 : pow(10.0, db / 20.0)
            let gain = Float(linear * (mixer.isAudible(program: instrument.program) ? 1 : 0))

            instrument.gain = gain
            instrument.node.volume = gain
        }
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
