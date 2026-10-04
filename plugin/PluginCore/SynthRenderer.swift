import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization
import os

/// The plugin's synth (Audio Unit design §2, "UI": the synth is an `InstrumentSynthBank` on an
/// `AVAudioEngine` inside the extension rendering into a buffer the render block mixes in). The
/// host's render thread must never wait on it, so it renders on a thread of its own, ahead of the
/// transport, into a ``SynthRing`` the render block reads.
///
/// ```
/// source node (schedules the bank, plays nothing)
/// synths ─▶ (the bank's sub-mix) ─▶ masterMixer ─▶ mainMixer ─▶ (manual output) ─▶ SynthRing
/// ```
///
/// The engine runs in offline manual rendering mode, as the app's `OfflineRenderer` runs its own:
/// the same bank and scheduler code, built with `live: false` (no MIDI out, no click, no meters),
/// and the same one buffer of lead -- the source node schedules `[t, t + chunk)` into the next
/// chunk, so a chunk's audio is the window scheduled in the one before.
///
/// Threading. The engine and the bank are made on the main thread and rendered on ``thread``.
/// Changes to the graph -- a synth per new instrument, the faders and mutes -- are queued for the
/// thread and made between two renders, never under one. The note list is swapped on the main
/// thread straight into the bank's scheduler, as the app swaps it, and an epoch is asked for so
/// the frames already ahead are rendered again with the new notes. The thread never touches the
/// host's render block or anything it holds but the ring.
///
/// Free of AU types (design §3).
nonisolated final class SynthRenderer: @unchecked Sendable {
    /// Frames per render: small, so a new epoch's frames are ready soon.
    static let chunkFrames = 256

    let ring: SynthRing
    let sampleRate: Double

    /// How far ahead of a moving consumer a new epoch begins: about 20 ms.
    let leadFrames: Int

    /// How far ahead of the consumer the thread renders: two of the host's largest blocks, and
    /// never less than 4 096 frames. A fader or a mute is heard this late at most.
    let aheadFrames: Int

    let bank: InstrumentSynthBank

    private let engine: AVAudioEngine
    private let masterMixer: AVAudioMixerNode
    private let sourceNode: AVAudioSourceNode
    private let window: ScheduleWindow
    private let buffer: AVAudioPCMBuffer

    private enum Command {
        case instruments([Int])
        case mixer(InstrumentMixerState)
    }

    private let commands = Mutex<[Command]>([])
    private let reanchorRequested = Atomic<Bool>(false)
    private let stopping = Atomic<Bool>(false)
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// Frames rendered and appended since the start, for the tests and the log.
    let renderedFrames = Atomic<Int>(0)

    /// The position the ring holds frames up to, from any thread.
    var renderedThrough: Int { ring.publishedHead }

    /// A renderer at `sampleRate` for a host whose blocks are at most `maxHostFrames`, with a ring
    /// sized for it; nil when the engine cannot be set up. Main thread.
    init?(sampleRate: Double, maxHostFrames: Int) {
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return nil }

        let chunk = SynthRenderer.chunkFrames
        let ahead = max(4096, 2 * max(maxHostFrames, 0))

        self.sampleRate = sampleRate
        leadFrames = (Int((sampleRate * 0.02).rounded(.up)) + chunk - 1) / chunk * chunk
        aheadFrames = (ahead + chunk - 1) / chunk * chunk
        ring = SynthRing(minimumFrames: 2 * aheadFrames + 2 * chunk)

        let engine = AVAudioEngine()

        do {
            // Before anything is attached: the output's format is the bank's render rate.
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(chunk))
        } catch {
            PluginLog.logger.error("synth: manual rendering refused: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(chunk))
        else { return nil }

        self.engine = engine
        self.buffer = buffer

        let masterMixer = AVAudioMixerNode()
        engine.attach(masterMixer)
        self.masterMixer = masterMixer
        let bank = InstrumentSynthBank(engine: engine, mixTarget: masterMixer, live: false)
        self.bank = bank

        // The crossfade, the master and the mutes' silence are the render block's and the mixer
        // state's; the bank's own sub-mix stays at unity.
        bank.synthGain = 1
        masterMixer.outputVolume = 1

        let window = ScheduleWindow()
        self.window = window
        sourceNode = AVAudioSourceNode(format: format, renderBlock: SynthRenderer.makeScheduleBlock(
            bank: bank, window: window, rate: sampleRate))

        engine.attach(sourceNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: format)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            PluginLog.logger.error("synth: engine did not start: \(error.localizedDescription, privacy: .public)")
            engine.detach(sourceNode)
            return nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Main thread

    /// The notes the synth plays from now on: a synth for each instrument made on the thread, the
    /// list swapped into the scheduler, and the frames ahead rendered again.
    func setNotes(_ notes: [NoteEvent]) {
        let programs = Set(notes.map(\.program)).filter { (0...NoteEvent.drumProgram).contains($0) }.sorted()

        commands.withLock { $0.append(.instruments(programs)) }
        bank.scheduler.swap(notes: notes.filter { (0...NoteEvent.drumProgram).contains($0.program) })
        requestEpoch()
    }

    /// The strips' faders, mutes and solos onto the synths, from the next chunk on.
    func setMixer(_ mixer: InstrumentMixerState) {
        commands.withLock { $0.append(.mixer(mixer)) }
        wake.signal()
    }

    /// Renders the frames ahead again: they were rendered with what has just changed.
    func requestEpoch() {
        reanchorRequested.store(true, ordering: .releasing)
        wake.signal()
    }

    /// Starts the thread, once.
    func start() {
        guard thread == nil else { return }

        let thread = Thread { [self] in
            self.run()
        }
        thread.name = "NeuralSheet synth"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the thread and waits for it (a chunk takes well under a millisecond), then the
    /// engine; the source node is detached, which lets go of the bank it holds. Any thread but the
    /// synth's; idempotent.
    func stop() {
        if thread != nil, !stopping.exchange(true, ordering: .acquiringAndReleasing) {
            wake.signal()
            _ = finished.wait(timeout: .now() + 2)
        }

        if engine.isRunning {
            engine.stop()
        }

        if sourceNode.engine != nil {
            engine.detach(sourceNode)
        }
    }

    // MARK: - The synth thread

    private func run() {
        SynthRenderer.setTimeConstraintPolicy()

        var seenGeneration: Int?
        var anchor = 0
        var scheduled = 0
        let chunk = SynthRenderer.chunkFrames

        while !stopping.load(ordering: .acquiring) {
            performCommands()

            let state = ring.consumerState()
            let requested = reanchorRequested.exchange(false, ordering: .acquiring)

            switch SynthRing.nextStep(state: state, seenGeneration: seenGeneration, reanchorRequested: requested,
                                      head: ring.head, lead: leadFrames, ahead: aheadFrames, chunk: chunk,
                                      capacity: ring.capacityFrames) {
            case .reanchor(let position):
                seenGeneration = state.generation
                anchor = position
                scheduled = position
                // What was sounding does not belong at the new position; the scheduler re-attacks
                // whatever covers it in the first chunk.
                bank.allNotesOff()
                bank.scheduler.seek(toSeconds: Double(position) / sampleRate)
                ring.beginEpoch(anchor: position, generation: state.generation)

            case .render:
                window.start = scheduled

                guard let status = try? engine.renderOffline(AVAudioFrameCount(chunk), to: buffer),
                      status == .success, let channels = buffer.floatChannelData
                else {
                    _ = wake.wait(timeout: .now() + .milliseconds(2))
                    continue
                }

                // This chunk sounds the window scheduled by the one before it.
                let audioStart = scheduled - chunk
                scheduled += chunk

                if audioStart >= anchor, audioStart == ring.head {
                    let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]
                    ring.append(left: channels[0], right: right, frames: Int(buffer.frameLength), tail: state.tail)
                    renderedFrames.wrappingAdd(Int(buffer.frameLength), ordering: .relaxed)
                }

            case .wait:
                _ = wake.wait(timeout: .now() + .milliseconds(2))
            }
        }

        finished.signal()
    }

    /// The graph changes queued by the main thread, between two renders.
    private func performCommands() {
        let queued = commands.withLock { pending in
            let taken = pending
            pending.removeAll()
            return taken
        }

        for command in queued {
            switch command {
            case .instruments(let programs):
                for program in programs { bank.ensureInstrument(program: program) }
            case .mixer(let mixer):
                bank.apply(mixer: mixer)
            }
        }
    }

    /// The source node's block: schedules the bank for the window the thread set, a chunk ahead,
    /// and plays nothing itself. Synth thread, inside `renderOffline`.
    private static func makeScheduleBlock(bank: InstrumentSynthBank, window: ScheduleWindow,
                                          rate: Double) -> AVAudioSourceNodeRenderBlock {
        { isSilence, timestamp, frameCount, audioBufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }

            let frames = Int(frameCount)
            let start = window.start

            bank.schedule(from: Double(start) / rate, to: Double(start + frames) / rate, renderTime: timestamp.pointee,
                          frameCount: frames, sampleRate: rate, outputRate: rate)

            isSilence.pointee = true
            return noErr
        }
    }

    /// The real-time band, as the app's MIDI sender sets it: the synth must keep ahead of the
    /// host. Failing to set it leaves the thread at `.userInteractive`.
    private static func setTimeConstraintPolicy() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        let ticksPerMillisecond = timebase.numer > 0 ? 1e6 * Double(timebase.denom) / Double(timebase.numer) : 1e6

        var policy = thread_time_constraint_policy_data_t(
            period: 0,
            computation: UInt32(2 * ticksPerMillisecond),
            constraint: UInt32(10 * ticksPerMillisecond),
            preemptible: 1)

        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)

        _ = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                thread_policy_set(
                    pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                    words, count)
            }
        }
    }
}

/// The window the source node schedules next, in timeline frames. Written and read on the synth
/// thread only: before `renderOffline` and inside it.
nonisolated final class ScheduleWindow: @unchecked Sendable {
    var start = 0
}
