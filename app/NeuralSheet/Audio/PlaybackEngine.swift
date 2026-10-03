import AVFoundation
import CoreAudio
import Foundation
import NeuralSheetCore
import Synchronization

/// Everything the render thread touches, in one object both ``PlaybackEngine`` and its render block
/// hold. The block captures this rather than the engine, so nothing it does can retain, release or
/// reach through `self` while the audio device is waiting.
///
/// `@unchecked Sendable`: every cross-thread field is an atomic, and the two plain `var`s are each
/// touched by exactly one thread (``previousSourceGain`` by the render block, ``meter`` by the tap).
private nonisolated final class RenderState: @unchecked Sendable {
    /// The take the render block reads, as a single machine word written only from the main thread.
    ///
    /// Unmanaged rather than a strong reference because a strong one in a class would be read
    /// through a lock-free-but-not-atomic sequence of loads; one pointer-sized slot is written and
    /// read atomically by the hardware. ``PlaybackEngine`` keeps the object itself alive, and keeps
    /// the one it replaced alive for a grace period, so the block can never see freed memory.
    let source = UnsafeMutablePointer<Unmanaged<SourceAudio>?>.allocate(capacity: 1)

    let playing = Atomic<Bool>(false)

    /// The playhead in frames at the device rate. The render block owns it; the main thread reads it
    /// and asks for changes through ``pendingSeek``.
    let playheadFrames = Atomic<Int>(0)

    /// A seek the render block has not applied yet, or -1 for none.
    let pendingSeek = Atomic<Int>(-1)

    /// `cos(mix · π/2) × masterGain`, muted folded in, as a `Float` bit pattern.
    let sourceGainBits = Atomic<UInt32>(0)

    /// Bumped every time the playhead runs off the end. The main thread polls it.
    let wrapGeneration = Atomic<Int>(0)

    /// The master meter's level, as a `Double` bit pattern.
    let masterLevelBits = Atomic<UInt64>(RmsMeter.floorDb.bitPattern)

    /// The loop as ``LoopWindow/packed``, 0 for none (loop design §4). One word, so the block
    /// never reads one end from a newer loop than the other.
    let loopBits = Atomic<UInt64>(0)

    /// The playback speed as a `Float` bit pattern, 1 for the take's own (speed design §4).
    let speedBits = Atomic<UInt32>(Float(1).bitPattern)

    /// Render thread only: the playhead to the fraction of a frame. ``playheadFrames`` is its
    /// rounding, published for the main thread; at any speed but 1 a block covers a fractional
    /// number of take frames and the fraction has to be kept somewhere.
    var playheadExact = 0.0

    /// Render thread only: where the last block's gain ramp ended.
    var previousSourceGain: Float = 0

    /// Render thread only: the stretch at any speed but 1, and whether the previous block used
    /// it (so it carries on rather than being reset). Replaced with the engine stopped when the
    /// rate changes. The scratch takes the stretcher's second channel when the output has one.
    var stretcher = TimeStretcher(sampleRate: 48000, maxBlockFrames: RenderState.maxBlockFrames)
    var stretching = false
    let stretchScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: RenderState.maxBlockFrames)

    /// The largest block the stretch path serves; a bigger one is silence rather than an overrun.
    static let maxBlockFrames = 8192

    /// Render thread only: the playhead the last rendered block started at, and whether that
    /// block was the one just before this. The take is read one buffer behind the playhead, and
    /// through a loop jump "one buffer behind" is the previous block's start, not `playhead -
    /// frames`.
    var lastBlockStart = 0
    var continuous = false

    /// Tap thread only. Replaced (with the engine stopped) when the device rate changes.
    var meter = RmsMeter(sampleRate: 48000)

    /// Tap thread only: room to fold a stereo tap buffer to mono without allocating.
    let meterScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16384)

    init() {
        source.initialize(to: nil)
        meterScratch.initialize(repeating: 0)
        stretchScratch.initialize(repeating: 0)
    }

    deinit {
        source.deinitialize(count: 1)
        source.deallocate()
        meterScratch.deallocate()
        stretchScratch.deallocate()
    }

    /// Tap thread. Folds the master mixer's output to mono and pushes it into the meter.
    func pushMeter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, let scratch = meterScratch.baseAddress else {
            return
        }

        let frames = Swift.min(Int(buffer.frameLength), meterScratch.count)
        guard frames > 0 else { return }

        let channels = Int(buffer.format.channelCount)

        if channels >= 2 {
            let left = data[0]
            let right = data[1]
            for i in 0..<frames {
                scratch[i] = (left[i] + right[i]) * 0.5
            }
        } else {
            scratch.update(from: data[0], count: frames)
        }

        meter.push(UnsafeBufferPointer(start: scratch, count: frames))
        masterLevelBits.store(meter.decibels.bitPattern, ordering: .relaxed)
    }
}

/// The AVAudioEngine graph: the source node that owns the playhead, the synth sub-mix, the master
/// fader and the meter after it.
///
/// ```
/// sourceNode ───────────────────────────────▶ mainMixer ─▶ output
/// synths ─▶ (bank sub-mix) ─▶ masterMixer ──▶
/// ```
///
/// The source node applies the master gain itself — the brief has it ramped inside the block — so it
/// joins the graph after ``masterMixer`` rather than through it; routing it through would apply the
/// fader twice. The meter tap sits on the main mixer, which is past both paths' master gain.
///
/// Threading: every method here is the main thread's unless it says otherwise. `@unchecked
/// Sendable` because the render block reaches the shared state through ``RenderState``'s atomics.
nonisolated final class PlaybackEngine: @unchecked Sendable {
    /// What the I/O unit is asked for. 128 frames at 48 kHz is 2.7 ms, which is what keeps the
    /// one-cycle-ahead MIDI scheduling from being audible as latency.
    static let requestedIOBufferFrames: UInt32 = 128

    /// How long the health check waits before its first retry, how far that doubles, and how many
    /// retries it gets before it stops and leaves ``lastStartError`` for the UI to show.
    private static let healBackoffSeconds = 0.25
    private static let healBackoffMaxSeconds = 5.0
    private static let healAttemptLimit = 8

    /// How long a replaced take is kept alive after the box stops pointing at it. Orders of
    /// magnitude more than one render cycle, which is all the block needs.
    private static let retirementSeconds = 0.5

    let engine = AVAudioEngine()

    /// The synth side of the graph. Its own sub-mix hangs off this, and the master fader is its
    /// output volume.
    private let masterMixer = AVAudioMixerNode()

    private let state = RenderState()

    let synthBank: InstrumentSynthBank

    private var sourceNode: AVAudioSourceNode?

    /// The device rate the graph is built for.
    private(set) var sampleRate: Double

    /// Strong reference to what the box points at.
    private var currentSource: SourceAudio?

    /// Takes the box no longer points at, held until the render block cannot be inside them.
    private var retiredSources: [SourceAudio] = []

    /// Polls ``RenderState/wrapGeneration``, so the render block never has to dispatch.
    private var wrapPoll: DispatchSourceTimer?
    private var lastWrapGeneration = 0

    private var meterTapInstalled = false
    var inputTapInstalled = false

    /// Guards ``rebuildGraph(_:)`` against re-entering itself.
    private var isRebuilding = false

    /// When the last rebuild finished, so a graph that cannot start is not rebuilt every tick.
    private var lastRebuild = Date.distantPast

    /// True between ``start()`` and ``stopEngine()``. What the health check compares the engine's
    /// actual state against.
    private var shouldRun = false

    /// How long the health check waits before its next attempt, and how many it has spent. Both are
    /// reset by a successful start, by Play and by the user choosing a device.
    private var healDelay = PlaybackEngine.healBackoffSeconds
    private var healAttempts = 0

    /// True once the health check has spent its budget on an engine that will not start, until a
    /// fresh budget is handed out. What ``onHealExhausted`` announces.
    private(set) var healExhausted = false

    /// Set while a failed device switch is being rolled back, so the rollback's `didSet` does not
    /// start another reconfiguration.
    var isRevertingDevice = false

    /// The frame count the device actually settled on, read back after the request. 0 before the
    /// engine has been started once.
    var ioBufferFrames = 0

    /// The last failure from pointing the I/O unit at a device, or nil if the last switch took. The
    /// published ``outputDevice``/``recordingInput`` is rolled back to what is really in use when this
    /// is set, so the two never disagree.
    var lastDeviceError: OSStatus?

    /// Why the last attempt to make a process tap failed, or nil when it was made: set beside
    /// ``lastDeviceError`` when the input that could not be used was System Audio or an app, so
    /// the model can tell a refused permission (`kAudioHardwareIllegalOperationError`) from a
    /// device that refused (system audio design §2). Only the next attempt clears it -- not the
    /// rebuild that follows a refusal, whose input is already back on a device.
    var lastTapError: OSStatus?

    /// Why the engine last refused to start, or nil if it is running or was stopped deliberately.
    private(set) var lastStartError: Error?

    /// Called on the main queue when the health check gives up: eight rebuilds, backed off to five
    /// seconds apart, and the engine is still not running. Play or a device pick starts it over.
    var onHealExhausted: (() -> Void)?

    /// The status of the last I/O buffer-size request, or nil if it was accepted. The size that
    /// came back is ``ioBufferFrames``, which is what the HAL settled on rather than what was asked.
    private(set) var lastIOBufferError: OSStatus?

    /// The devices the I/O units were last pointed at successfully, so a rejected switch has
    /// something to fall back to when the unit cannot name what it is on.
    var lastAppliedOutputDevice: AudioDevice?
    var lastAppliedRecordingInput: RecordingInput?

    /// The private aggregate the I/O unit is on, when the chosen devices needed one, the pair it
    /// stands for and the process tap inside it, if any. Ours to destroy -- the aggregate, then
    /// its tap -- and reused for as long as that pair does not change.
    var aggregate: Aggregate?

    /// Set once by ``shutDown()``: from then on nothing starts the engine or makes an aggregate
    /// or a tap again.
    var isShutDown = false

    /// Called on the main queue when the app a take is tapping has quit (system audio design §2),
    /// outside the HAL's listener callback. The take is the model's to end.
    var onTappedProcessExited: (() -> Void)?

    /// Called on the main queue when the playhead reaches the end. The transport has already been
    /// stopped and rewound by then.
    var onPlayheadWrapped: (() -> Void)?

    /// Called on the main queue on every tick of the 30 Hz poll, for the count-in's state
    /// machine (click design §2), which reads the click's clock and downbeat off the synth bank.
    var onPoll: (() -> Void)?

    /// Set by the Recorder: installed on the input node's bus 0 with 1024-frame buffers. Setting it
    /// to nil removes the tap. The engine never routes the input to the output.
    var inputTap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        didSet { refreshInputTap() }
    }

    /// What the input tap delivers: the rate and channel count a recording is written at.
    ///
    /// Read it after ``inputTap`` has been set, never before. Setting the tap is what points the
    /// input unit at ``recordingInput``, and until then the node answers for the device it was on.
    /// Reading it also instantiates the input node, which is what asks for microphone access.
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    var outputDevice: AudioDevice? {
        didSet {
            guard !isRevertingDevice, outputDevice != oldValue else { return }
            reconfigureDevices()
        }
    }

    /// What the next take records from: a device, System Audio or one app (system audio design
    /// §2); nil is the system's default input. A tap is only made while the input is pulled --
    /// from Record to stop -- as a microphone's aggregate is.
    var recordingInput: RecordingInput? {
        didSet {
            guard !isRevertingDevice, recordingInput != oldValue else { return }
            reconfigureDevices()
        }
    }

    /// The equal-power crossfade between the source audio and the synth, 0…1. Under
    /// ``stereoSplit`` only its ends mean anything: exactly 0 or 1 is a hold on that side alone.
    var mix: Double = 0.5 {
        didSet { updateGains() }
    }

    /// The source in the left ear and the synth in the right, each at full, nothing mixed. Panned
    /// at the main mixer from this thread, so the render block is none the wiser.
    var stereoSplit: Bool = false {
        didSet { updateGains() }
    }

    /// The master fader, −36…+6 dB, where −36 is silence.
    var masterGainDb: Double = 0 {
        didSet { updateGains() }
    }

    var muted: Bool = false {
        didSet { updateGains() }
    }

    /// The stretch of the take playback repeats, in seconds, or nil to play through to the end
    /// (loop design §4). Clamped to the take and converted at the device rate here, and again
    /// whenever either changes.
    var loop: Range<Double>? {
        didSet { applyLoop() }
    }

    /// How fast the take plays, its pitch unchanged: 0.5 is half speed (speed design §4). The
    /// MIDI clock follows it. Clamped to what the stretch handles.
    var speed: Double = 1 {
        didSet {
            let clamped = speed.isFinite ? min(max(speed, TimeStretcher.minSpeed), TimeStretcher.maxSpeed) : 1
            state.speedBits.store(Float(clamped).bitPattern, ordering: .relaxed)

            // The notes the DAW holds were timed for the old speed (MIDI out design §2).
            if speed != oldValue { synthBank.midiOut.panic() }
        }
    }

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = rate > 0 ? rate : 44100

        engine.attach(masterMixer)
        synthBank = InstrumentSynthBank(engine: engine, mixTarget: masterMixer)

        buildGraph()
        updateGains()
    }

    deinit {
        wrapPoll?.cancel()
        if meterTapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
        if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        // The aggregate, then the tap in it.
        aggregate?.destroy()
    }

    // MARK: - Transport

    var isPlaying: Bool { state.playing.load(ordering: .relaxed) }

    /// Whether the AVAudioEngine is actually rendering, whatever was asked of it.
    var isRunning: Bool { engine.isRunning }

    func play() {
        // An audition still sounding holds the synth side at unity; the take must play under the
        // crossfade that is set.
        synthBank.stopAudition()
        // A wrap the poll has not picked up yet belongs to the run that just ended: without this,
        // pressing play right after the take finished would immediately re-anchor and announce it.
        supersedePendingWrap()
        // The MIDI output's channels get their programs and controllers ahead of the first note
        // (MIDI out design §2).
        synthBank.midiOut.resendControls()
        state.playing.store(true, ordering: .relaxed)
        retryStartIfNeeded()
    }

    func pause() {
        state.playing.store(false, ordering: .relaxed)
        synthBank.scheduler.requestAllNotesOff()
        synthBank.allNotesOff()
        // The synths' CC 123 does not reach a MIDI destination (MIDI out design §2).
        synthBank.midiOut.panic()
    }

    /// Pause and rewind, which is what the Back button does.
    func stop() {
        pause()
        setPlayhead(frames: 0, seconds: 0)
    }

    /// Ignored unless `0 <= seconds < duration`, exactly as the C++ player does it: a click past the
    /// end of the take is not a seek to the end, it is nothing.
    func seek(seconds: Double) {
        guard let source = currentSource, seconds >= 0, seconds < source.duration else { return }

        let frames = Int((seconds * sampleRate).rounded())
        setPlayhead(frames: max(0, min(frames, max(0, source.frameCount - 1))), seconds: seconds)
    }

    /// Where the playhead is now. A seek that the render block has not picked up yet reads as
    /// already applied, so the UI does not flick back for a block.
    var playheadSeconds: Double {
        let pending = state.pendingSeek.load(ordering: .relaxed)
        let frames = pending >= 0 ? pending : state.playheadFrames.load(ordering: .relaxed)

        return Double(frames) / sampleRate
    }

    /// The master meter's level after the fader.
    var masterLevelDb: Double { Double(bitPattern: state.masterLevelBits.load(ordering: .relaxed)) }

    private func setPlayhead(frames: Int, seconds: Double) {
        supersedePendingWrap()
        state.pendingSeek.store(frames, ordering: .relaxed)
        synthBank.scheduler.seek(toSeconds: seconds)
        // The scheduler's note-offs are not enough on their own: drums are one-shot and the synth
        // ignores a note-off for them, so a seek has to silence the synth directly. The MIDI
        // output the same, and its channels set up again for the notes from the new position.
        synthBank.allNotesOff()
        synthBank.midiOut.panic()
        synthBank.midiOut.resendControls()
    }

    // MARK: - Source

    /// Swaps in a new take, or clears the current one. The transport stops and rewinds either way.
    ///
    /// Re-resamples when the take was built for a different device rate, which is what happens when
    /// a session is restored onto different hardware or the output device changes mid-session.
    func setSource(_ audio: SourceAudio?) {
        pause()

        let prepared = audio.map { $0.deviceRate == sampleRate ? $0 : $0.resampled(to: sampleRate) }
        let retiring = currentSource

        currentSource = prepared
        state.source.pointee = prepared.map { Unmanaged.passUnretained($0) }

        supersedePendingWrap()
        state.playheadFrames.store(0, ordering: .relaxed)
        // As a seek rather than a store into the frames alone: the block keeps the exact
        // position in a field of its own, and only a seek reaches it.
        state.pendingSeek.store(0, ordering: .relaxed)
        synthBank.scheduler.seek(toSeconds: 0)
        synthBank.allNotesOff()

        // The window is clamped to the take, so a new take means clamping it again.
        applyLoop()

        retire(retiring)
    }

    /// Hands the render block the loop as frames at the current rate, clamped to the current
    /// take; 0 -- no loop -- with no take or a window that does not fit it.
    private func applyLoop() {
        let window = loop.flatMap { seconds in
            currentSource.flatMap { source in
                LoopWindow(seconds: seconds, sampleRate: sampleRate, frameCount: source.frameCount)
            }
        }

        state.loopBits.store(window?.packed ?? 0, ordering: .relaxed)
    }

    /// A wrap the poll has not picked up yet is superseded by an explicit seek or a new take: the
    /// transport is where it has just been put, not at an end it passed a few milliseconds ago.
    /// Without this the poll would re-anchor the scheduler and announce the wrap up to 33 ms late,
    /// on top of a position the user had already chosen.
    private func supersedePendingWrap() {
        lastWrapGeneration = state.wrapGeneration.load(ordering: .relaxed)
    }

    /// Holds a replaced take until any render block that saw it has long since returned.
    private func retire(_ source: SourceAudio?) {
        guard let source else { return }

        retiredSources.append(source)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retirementSeconds) { [weak self] in
            guard let self else { return }
            if let index = self.retiredSources.firstIndex(where: { $0 === source }) {
                self.retiredSources.remove(at: index)
            }
        }
    }

    // MARK: - Engine lifecycle

    /// Starts the engine, or throws why it would not. Either way the engine now *should* be
    /// running: a refusal at launch -- the output device busy, or not there yet -- leaves the poll
    /// running and the health check retrying with its backoff, so the failure is a delay rather
    /// than a silent session. The error stays in ``lastStartError`` for the UI to show.
    func start() throws {
        guard !engine.isRunning, !isShutDown else { return }

        shouldRun = true
        resetHealBudget()

        applyDevices()

        // Before `prepare()`, not after `start()`: `prepare()` initialises the AUHAL, and an
        // initialised unit answers kAudioUnitErr_Initialized to a buffer-size request.
        let bufferStatus = requestIOBufferSize()
        lastIOBufferError = bufferStatus == noErr ? nil : bufferStatus

        engine.prepare()

        // The poll first, whatever `start()` says: it is what carries the retries.
        startWrapPoll()

        do {
            try engine.start()
            lastStartError = nil
        } catch {
            lastStartError = error
            throw error
        }

        readIOBufferSize()
    }

    /// A user gesture that wants the output -- Play, a device pick -- hands the health check a
    /// fresh budget, and when the engine is not running makes one attempt now rather than at the
    /// poll's next tick. Not from inside a rebuild, whose own attempt is under way.
    func retryStartIfNeeded() {
        guard !isRebuilding, !isShutDown else { return }

        resetHealBudget()

        guard !engine.isRunning else { return }

        try? start()
    }

    func resetHealBudget() {
        healAttempts = 0
        healDelay = Self.healBackoffSeconds
        healExhausted = false
    }

    func stopEngine() {
        shouldRun = false
        wrapPoll?.cancel()
        wrapPoll = nil
        engine.stop()
    }

    // MARK: - Graph

    private func buildGraph() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return }

        state.meter = RmsMeter(sampleRate: sampleRate)
        // Its windows are seconds, so a new rate means new buffers. The engine is stopped.
        state.stretcher = TimeStretcher(sampleRate: sampleRate, maxBlockFrames: RenderState.maxBlockFrames)
        state.stretching = false

        let node = AVAudioSourceNode(format: format, renderBlock: makeRenderBlock())
        sourceNode = node

        engine.attach(node)

        // Explicitly, and to the hardware's own format: a device change can hand the output node a
        // different channel count, and the implicit main-mixer connection keeps the one it was made
        // with, which leaves the engine refusing to start.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) {
            [state] buffer, _ in
            state.pushMeter(buffer)
        }
        meterTapInstalled = true
    }

    private func teardownGraph() {
        if meterTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            meterTapInstalled = false
        }

        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }

        engine.disconnectNodeOutput(masterMixer)
    }

    /// CoreAudio reshaping the graph under the engine — the default device changing, a device going
    /// away, the format the hardware settles on after a switch — stops the engine and invalidates
    /// its connections, sometimes a moment after the call that caused it returned. Rather than
    /// chasing the notification, the poll that watches for the end of the take also watches for an
    /// engine that should be running and is not, and rebuilds it.
    private func healIfNeeded() {
        guard shouldRun, !engine.isRunning, !isRebuilding,
            healAttempts < Self.healAttemptLimit,
            Date().timeIntervalSince(lastRebuild) > healDelay
        else { return }

        healAttempts += 1
        rebuildGraph {}

        if engine.isRunning {
            resetHealBudget()
        } else {
            // Backing off rather than hammering: an engine that cannot start is usually waiting on
            // hardware that is not coming back, and a full graph rebuild four times a second for
            // the rest of the session is worse than giving up and saying so.
            healDelay = Swift.min(healDelay * 2, Self.healBackoffMaxSeconds)

            if healAttempts >= Self.healAttemptLimit {
                healExhausted = true
                onHealExhausted?()
            }
        }
    }

    /// The common path for "the hardware underneath us changed": our own device switch, and the
    /// health check finding an engine that stopped on its own.
    func rebuildGraph(_ beforeRebuild: () -> Void) {
        guard !isRebuilding, !isShutDown else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        let wasRunning = engine.isRunning
        let wasPlaying = isPlaying
        let position = playheadSeconds

        engine.stop()
        teardownGraph()

        beforeRebuild()

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 { sampleRate = rate }

        buildGraph()
        // The synths kept their nodes through the rebuild, but not necessarily the rate.
        synthBank.reconnectForCurrentRate()
        updateGains()

        // The take is stored at the device rate, so new hardware means converting it again.
        if let source = currentSource, source.deviceRate != sampleRate {
            setSource(source)
        }

        // The loop is frames at the device rate, so a new rate means converting it again.
        applyLoop()

        refreshInputTap()

        // `shouldRun` as well as `wasRunning`: the health check only calls this because the engine
        // has already stopped on its own, and that is exactly the case that has to come back up.
        if wasRunning || shouldRun {
            let bufferStatus = requestIOBufferSize()
            lastIOBufferError = bufferStatus == noErr ? nil : bufferStatus

            engine.prepare()

            do {
                try engine.start()
                lastStartError = nil
            } catch {
                lastStartError = error
            }

            readIOBufferSize()
        }

        // The transport survives a device change: the playhead is a position in the take, not in
        // the hardware.
        seek(seconds: position)
        if wasPlaying { play() }

        lastRebuild = Date()
    }

    // MARK: - Error text

    /// An `OSStatus` for a dialog: the number, and its four-character code when it has one
    /// (`560227702 ('!dev')`); a small negative code such as -10851 is the number alone.
    static func describe(_ status: OSStatus) -> String {
        let bits = UInt32(bitPattern: status)
        let bytes = (0..<4).map { UInt8((bits >> (8 * UInt32(3 - $0))) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }

        guard printable, let code = String(bytes: bytes, encoding: .ascii) else {
            return "\(status)"
        }

        return "\(status) ('\(code)')"
    }

    /// An `Error` for a dialog: CoreAudio's status codes as ``describe(_:)`` has them, anything
    /// else as it describes itself.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == NSOSStatusErrorDomain || nsError.domain.hasPrefix("com.apple.coreaudio") {
            return "CoreAudio error \(describe(OSStatus(truncatingIfNeeded: nsError.code)))"
        }

        return nsError.localizedDescription
    }

    // MARK: - Gains

    /// Re-applies the gains from outside. The mix depends on whether the scheduler has any notes
    /// (§5.3), which changes when a decoded chunk arrives rather than when a control moves.
    func refreshGains() {
        updateGains()
    }

    /// The gains through ``MixLaw``, the one formula the offline renderer shares (audio export
    /// design §2).
    private func updateGains() {
        let gains = MixLaw.resolve(mix: mix, masterGainDb: masterGainDb, muted: muted, stereoSplit: stereoSplit,
                                   hasNotes: synthBank.scheduler.hasNotes)

        state.sourceGainBits.store(gains.source.bitPattern, ordering: .relaxed)
        synthBank.synthGain = gains.synth
        masterMixer.outputVolume = gains.master
        // The pans are the main mixer's input settings, re-applied here so a graph rebuilt for
        // another device gets them back with its gains.
        sourceNode?.pan = gains.stereoSplit ? -1 : 0
        masterMixer.pan = gains.stereoSplit ? 1 : 0
    }

    // MARK: - Wrap notification

    private func startWrapPoll() {
        wrapPoll?.cancel()
        lastWrapGeneration = state.wrapGeneration.load(ordering: .relaxed)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            self.healIfNeeded()
            self.onPoll?()

            let generation = self.state.wrapGeneration.load(ordering: .relaxed)
            guard generation != self.lastWrapGeneration else { return }

            self.lastWrapGeneration = generation

            // The current playhead, not 0: the block rewound to 0 when it wrapped, but up to 33 ms
            // have passed and a seek in that window has already moved the transport somewhere else.
            self.synthBank.scheduler.seek(toSeconds: self.playheadSeconds)
            self.synthBank.allNotesOff()
            self.synthBank.midiOut.panic()
            self.onPlayheadWrapped?()
        }
        timer.resume()
        wrapPoll = timer
    }

    // MARK: - Render

    private func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        let state = self.state
        let bank = self.synthBank
        let rate = sampleRate

        return { isSilence, timestamp, frameCount, audioBufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            // Gains are ramped from where the last block ended, so a fader move does not step.
            let targetGain = Float(bitPattern: state.sourceGainBits.load(ordering: .relaxed))
            let startGain = state.previousSourceGain
            state.previousSourceGain = targetGain

            let seek = state.pendingSeek.exchange(-1, ordering: .relaxed)
            var playhead = state.playheadExact
            if seek >= 0 { playhead = Double(seek) }

            let playing = state.playing.load(ordering: .relaxed)
            let source = state.source.pointee?.takeUnretainedValue()
            let loop = LoopWindow(packed: state.loopBits.load(ordering: .relaxed))
            let speed = Double(Float(bitPattern: state.speedBits.load(ordering: .relaxed)))
            // The take frames this block covers: `frames` at the take's own speed.
            let span = Double(frames) * speed

            let startSeconds = playhead / rate
            var endSeconds = startSeconds
            var rendered = false
            var wrapped = false

            if playing, let source, source.frameCount > 0, frames > 0 {
                let total = source.frameCount
                let step = (targetGain - startGain) / Float(frames)
                let outputs = min(buffers.count, 2)

                if speed != 1 {
                    // The stretch (speed design §4). It reads the take itself, through the same
                    // wrapped index as the direct read, and keeps its own place in it from one
                    // block to the next; a seek, a block that did not render or a return from
                    // speed 1 starts it again one block behind the playhead, where the direct
                    // read would be.
                    let input = TimeStretcher.Input(
                        left: source.base(ofChannel: 0),
                        right: source.base(ofChannel: min(1, source.channelCount - 1)),
                        frameCount: total, isStereo: source.channelCount > 1, loop: loop)

                    if !state.stretching || seek >= 0 {
                        state.stretcher.reset(at: playhead - span, input: input)
                    }

                    state.stretcher.speed = speed

                    if let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                        let scratch = state.stretchScratch.baseAddress, frames <= RenderState.maxBlockFrames
                    {
                        let rightOutput = outputs > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
                        let right = rightOutput ?? scratch

                        state.stretcher.render(left: left, right: right, frames: frames, input: input)

                        var gain = startGain
                        for i in 0..<frames {
                            left[i] *= gain
                            if rightOutput != nil { right[i] *= gain }
                            gain += step
                        }
                    }

                    state.stretching = true
                    // The direct read's continuity is broken: it comes back a block behind.
                    state.continuous = false
                } else {
                    let blockStart = Int(playhead.rounded())
                    // One buffer behind the playhead: the MIDI for [playhead, playhead + buffer)
                    // is being scheduled a cycle ahead, and this delay is what keeps the two
                    // aligned. Through a loop jump the buffer behind is the previous block's
                    // start, which is the same thing until the jump and the right thing after it
                    // (loop design §4).
                    let readStart = seek < 0 && state.continuous ? state.lastBlockStart : blockStart - frames

                    for channel in 0..<outputs {
                        guard let output = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                        else { continue }

                        // A mono take feeds both outputs.
                        let base = source.base(
                            ofChannel: min(channel, source.channelCount - 1))
                        var gain = startGain

                        for i in 0..<frames {
                            // A read window that crosses the loop's end takes the rest from its
                            // start.
                            let index = loop?.wrapped(readStart + i) ?? (readStart + i)
                            let sample = index >= 0 && index < total ? base[index] : 0
                            output[i] = sample * gain
                            gain += step
                        }
                    }

                    state.lastBlockStart = blockStart
                    state.continuous = true
                    state.stretching = false
                }

                rendered = true

                if let loop {
                    // The synth stops at the loop's end; the playhead carries the overshoot past
                    // its start. The end of the take is never reached: the jump comes first.
                    let advanced = loop.advance(from: playhead, span: span)
                    endSeconds = advanced.renderEnd / rate
                    playhead = advanced.next
                } else {
                    playhead += span
                    endSeconds = playhead / rate

                    // `playhead - span` is where this block started: once that is at or past
                    // the end, every sample has been handed over and the take is done.
                    if playhead - span >= Double(total) {
                        playhead = 0
                        state.playing.store(false, ordering: .relaxed)
                        wrapped = true
                    }
                }
            } else {
                // A block that did not render breaks both runs: the next one reads a buffer
                // behind wherever the playhead is by then.
                state.continuous = false
                state.stretching = false
            }

            state.playheadExact = playhead
            state.playheadFrames.store(Int(playhead.rounded()), ordering: .relaxed)

            // After the playhead store, not before: the poll re-anchors the scheduler to
            // ``playheadSeconds``, and bumping the generation first would let it read the position
            // the block is about to replace.
            if wrapped {
                state.wrapGeneration.wrappingAdd(1, ordering: .relaxed)
            }

            // Every block, playing or not: a stop, a seek or a swapped note list all leave
            // note-offs to deliver and this is what delivers them.
            // At `rate / speed`: a note Δ seconds into the block lands Δ × rate / speed output
            // frames in, and its length stretches with the audio (speed design §2).
            bank.schedule(
                from: startSeconds,
                to: endSeconds,
                renderTime: timestamp.pointee,
                frameCount: frames,
                sampleRate: rate / speed,
                outputRate: rate
            )

            isSilence.pointee = ObjCBool(!rendered)

            return noErr
        }
    }
}
