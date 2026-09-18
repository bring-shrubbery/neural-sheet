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

    /// Render thread only: where the last block's gain ramp ended.
    var previousSourceGain: Float = 0

    /// Tap thread only. Replaced (with the engine stopped) when the device rate changes.
    var meter = RmsMeter(sampleRate: 48000)

    /// Tap thread only: room to fold a stereo tap buffer to mono without allocating.
    let meterScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16384)

    init() {
        source.initialize(to: nil)
        meterScratch.initialize(repeating: 0)
    }

    deinit {
        source.deinitialize(count: 1)
        source.deallocate()
        meterScratch.deallocate()
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
    private static let requestedIOBufferFrames: UInt32 = 128

    /// How long the health check waits before its first retry, how far that doubles, and how many
    /// retries it gets before it stops and leaves ``lastStartError`` for the UI to show.
    private static let healBackoffSeconds = 0.25
    private static let healBackoffMaxSeconds = 5.0
    private static let healAttemptLimit = 8

    /// The fader's silent end, matching `InstrumentMixerState.minGainDb`.
    private static let minGainDb = -36.0
    private static let maxGainDb = 6.0

    /// How long a replaced take is kept alive after the box stops pointing at it. Orders of
    /// magnitude more than one render cycle, which is all the block needs.
    private static let retirementSeconds = 0.5

    private let engine = AVAudioEngine()

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
    private var inputTapInstalled = false

    /// Guards ``rebuildGraph(_:)`` against re-entering itself.
    private var isRebuilding = false

    /// When the last rebuild finished, so a graph that cannot start is not rebuilt every tick.
    private var lastRebuild = Date.distantPast

    /// True between ``start()`` and ``stopEngine()``. What the health check compares the engine's
    /// actual state against.
    private var shouldRun = false

    /// How long the health check waits before its next attempt, and how many it has spent. Both are
    /// reset by a successful start and by the user choosing a device.
    private var healDelay = PlaybackEngine.healBackoffSeconds
    private var healAttempts = 0

    /// Set while a failed device switch is being rolled back, so the rollback's `didSet` does not
    /// start another reconfiguration.
    private var isRevertingDevice = false

    /// The frame count the device actually settled on, read back after the request. 0 before the
    /// engine has been started once.
    private(set) var ioBufferFrames = 0

    /// The last failure from pointing the I/O unit at a device, or nil if the last switch took. The
    /// published ``outputDevice``/``inputDevice`` is rolled back to what is really in use when this
    /// is set, so the two never disagree.
    private(set) var lastDeviceError: OSStatus?

    /// Why the engine last refused to start, or nil if it is running or was stopped deliberately.
    private(set) var lastStartError: Error?

    /// The status of the last I/O buffer-size request, or nil if it was accepted. The size that
    /// came back is ``ioBufferFrames``, which is what the HAL settled on rather than what was asked.
    private(set) var lastIOBufferError: OSStatus?

    /// The devices the I/O units were last pointed at successfully, so a rejected switch has
    /// something to fall back to when the unit cannot name what it is on.
    private var lastAppliedOutputDevice: AudioDevice?
    private var lastAppliedInputDevice: AudioDevice?

    /// The aggregate the I/O unit is on, when a chosen input needed one. Ours to destroy.
    private var inputAggregate: AudioDeviceID?

    /// Called on the main queue when the playhead reaches the end. The transport has already been
    /// stopped and rewound by then.
    var onPlayheadWrapped: (() -> Void)?

    /// Set by the Recorder: installed on the input node's bus 0 with 1024-frame buffers. Setting it
    /// to nil removes the tap. The engine never routes the input to the output.
    var inputTap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        didSet { refreshInputTap() }
    }

    /// What the input tap delivers: the rate and channel count a recording is written at.
    ///
    /// Read it after ``inputTap`` has been set, never before. Setting the tap is what points the
    /// input unit at ``inputDevice``, and until then the node answers for the device it was on.
    /// Reading it also instantiates the input node, which is what asks for microphone access.
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    var outputDevice: AudioDevice? {
        didSet {
            guard !isRevertingDevice, outputDevice != oldValue else { return }
            reconfigureDevices()
        }
    }

    var inputDevice: AudioDevice? {
        didSet {
            guard !isRevertingDevice, inputDevice != oldValue else { return }
            reconfigureDevices()
        }
    }

    /// The equal-power crossfade between the source audio and the synth, 0…1.
    var mix: Double = 0.5 {
        didSet { updateGains() }
    }

    /// The master fader, −36…+6 dB, where −36 is silence.
    var masterGainDb: Double = 0 {
        didSet { updateGains() }
    }

    var muted: Bool = false {
        didSet { updateGains() }
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
        InputAggregate.destroy(inputAggregate)
    }

    // MARK: - Transport

    var isPlaying: Bool { state.playing.load(ordering: .relaxed) }

    func play() {
        state.playing.store(true, ordering: .relaxed)
    }

    func pause() {
        state.playing.store(false, ordering: .relaxed)
        synthBank.scheduler.requestAllNotesOff()
        synthBank.allNotesOff()
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
        // ignores a note-off for them, so a seek has to silence the synth directly.
        synthBank.allNotesOff()
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
        state.pendingSeek.store(-1, ordering: .relaxed)
        synthBank.scheduler.seek(toSeconds: 0)
        synthBank.allNotesOff()

        retire(retiring)
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

    func start() throws {
        guard !engine.isRunning else { return }

        shouldRun = true
        healAttempts = 0
        healDelay = Self.healBackoffSeconds

        applyDevices()

        // Before `prepare()`, not after `start()`: `prepare()` initialises the AUHAL, and an
        // initialised unit answers kAudioUnitErr_Initialized to a buffer-size request.
        let bufferStatus = requestIOBufferSize()
        lastIOBufferError = bufferStatus == noErr ? nil : bufferStatus

        engine.prepare()

        do {
            try engine.start()
            lastStartError = nil
        } catch {
            lastStartError = error
            shouldRun = false
            throw error
        }

        readIOBufferSize()
        startWrapPoll()
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

    /// Stops the engine, points the I/O unit at the chosen devices, builds the graph again against
    /// whatever the new hardware's format turns out to be, and starts it back up.
    ///
    /// The whole graph, not just the parts that look stale: new hardware can change the sample rate
    /// and the channel count, and a connection made against the old one is what makes `start()`
    /// return quietly without running.
    private func reconfigureDevices() {
        // A device the user just chose gets a fresh budget: whatever made the last one unstartable
        // has nothing to say about this one.
        healAttempts = 0
        healDelay = Self.healBackoffSeconds

        rebuildGraph { self.applyDevices() }
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
            healAttempts = 0
            healDelay = Self.healBackoffSeconds
        } else {
            // Backing off rather than hammering: an engine that cannot start is usually waiting on
            // hardware that is not coming back, and a full graph rebuild four times a second for
            // the rest of the session is worse than giving up and saying so.
            healDelay = Swift.min(healDelay * 2, Self.healBackoffMaxSeconds)
        }
    }

    /// The common path for "the hardware underneath us changed": our own device switch, and the
    /// health check finding an engine that stopped on its own.
    private func rebuildGraph(_ beforeRebuild: () -> Void) {
        guard !isRebuilding else { return }
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
        updateGains()

        // The take is stored at the device rate, so new hardware means converting it again.
        if let source = currentSource, source.deviceRate != sampleRate {
            setSource(source)
        }

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

    private func applyDevices() {
        lastDeviceError = nil

        if let outputDevice {
            let status = Self.setDevice(outputDevice.id, on: engine.outputNode)
            if status == noErr {
                lastAppliedOutputDevice = outputDevice
            } else {
                lastDeviceError = status
                revert(\.outputDevice, on: engine.outputNode, fallback: lastAppliedOutputDevice)
            }
        }

        // The input node is only touched once something wants the input: instantiating it asks for
        // microphone access, and playback alone has no business doing that. Dropping a chosen input
        // is the exception -- the aggregate standing behind it has to go either way.
        if inputTap != nil || inputTapInstalled || inputAggregate != nil {
            applyInputDevice()
        }
    }

    /// Points the I/O unit at ``inputDevice``, through a private aggregate when that is a different
    /// box from the one playing.
    ///
    /// One unit serves both directions, so this decides where the output goes as well: the aggregate
    /// carries the output device alongside the chosen input, which is the only way the two can be
    /// different. See ``InputAggregate`` for why a bare `setDevice` cannot do it.
    private func applyInputDevice() {
        let outputID = outputDevice?.id ?? AudioDevices.defaultOutput()?.id

        guard let inputDevice else {
            // Nothing wants a particular input any more: back to the device that is playing, and
            // the aggregate that was only ever there to bolt an input onto it can go.
            if inputAggregate != nil {
                if let outputID { Self.setDevice(outputID, on: engine.outputNode) }
                InputAggregate.destroy(inputAggregate)
                inputAggregate = nil
            }
            return
        }

        let aggregate = outputID.flatMap { InputAggregate.create(input: inputDevice.id, output: $0) }
        let status = Self.setDevice(aggregate ?? inputDevice.id, on: engine.inputNode)

        // Only once the unit is off it, which the set above has just seen to.
        let previous = inputAggregate
        inputAggregate = nil

        if status == noErr {
            inputAggregate = aggregate
            lastAppliedInputDevice = inputDevice
        } else {
            InputAggregate.destroy(aggregate)
            lastDeviceError = status

            // A refused switch does not leave the unit as it was: it can clear the device outright,
            // which silences playback too. Put the one that plays back before publishing anything.
            if Self.currentDevice(of: engine.outputNode) == nil, let outputID {
                Self.setDevice(outputID, on: engine.outputNode)
            }

            revert(\.inputDevice, on: engine.inputNode, fallback: lastAppliedInputDevice)
        }

        InputAggregate.destroy(previous)
    }

    /// Puts the published choice back to the device the I/O unit is really on, so a rejected switch
    /// does not leave the picker naming something that is not playing.
    private func revert(
        _ key: ReferenceWritableKeyPath<PlaybackEngine, AudioDevice?>,
        on node: AVAudioIONode,
        fallback: AudioDevice?
    ) {
        // By id, not by looking the id up in the pickers' lists: the unit can be on something the
        // lists leave out, and naming it is still better than publishing nil.
        let inUse = Self.currentDevice(of: node).flatMap(AudioDevices.device(withID:))

        isRevertingDevice = true
        self[keyPath: key] = inUse ?? fallback
        isRevertingDevice = false
    }

    @discardableResult
    private static func setDevice(_ id: AudioDeviceID, on node: AVAudioIONode) -> OSStatus {
        guard let unit = node.audioUnit else { return OSStatus(kAudioUnitErr_Uninitialized) }

        var deviceID = id

        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Which device the node's I/O unit is on right now, whatever was asked for.
    private static func currentDevice(of node: AVAudioIONode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
            &size)

        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    /// Asks for the small I/O buffer, before the engine is prepared.
    ///
    /// Two routes, because neither works on its own: the AUHAL takes the property only while it is
    /// uninitialised, and it stays initialised across a stop, so a restart has to go to the device
    /// instead. The request is advisory either way — the HAL clamps it to what the device supports
    /// and to what other clients have asked for — which is why ``readIOBufferSize()`` reports what
    /// actually happened rather than what was asked.
    private func requestIOBufferSize() -> OSStatus {
        var frames = Self.requestedIOBufferFrames
        let size = UInt32(MemoryLayout<UInt32>.size)

        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitSetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &frames)
        }

        return status
    }

    /// Reads back the frame count the device settled on into ``ioBufferFrames``.
    @discardableResult
    private func readIOBufferSize() -> Int {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitGetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        }

        ioBufferFrames = status == noErr ? Int(frames) : 0

        return ioBufferFrames
    }

    /// Puts the tap on or takes it off, and restarts the engine when that changed whether the input
    /// node is in use at all.
    ///
    /// The restart is not optional: the I/O unit enables its input side when the engine starts, from
    /// whether anything is pulling the input node, so a tap installed on an engine that started
    /// without one is never called. Coming back through ``rebuildGraph(_:)`` is what re-enables it.
    private func refreshInputTap() {
        let wasInstalled = inputTapInstalled

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        defer {
            if inputTapInstalled != wasInstalled {
                // A no-op while a rebuild is already in flight, which is where this call came from.
                rebuildGraph {}
            }
        }

        guard let inputTap else { return }

        // Before the format is read, not after: the node reports the format of the device its unit
        // is on, and a tap installed with the last device's rate captures at the wrong one.
        applyInputDevice()

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // nil, not the format just read: a device switch settles a moment after it is asked for, and
        // an explicit format that no longer matches the node's live one is an uncatchable ObjC
        // exception out of `installTap`. The tap's own buffers carry the format either way.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            inputTap(buffer, time)
        }
        inputTapInstalled = true
    }

    // MARK: - Gains

    private func updateGains() {
        let angle = min(max(mix, 0), 1) * Double.pi / 2
        let db = min(max(masterGainDb, Self.minGainDb), Self.maxGainDb)
        // -36 dB is the fader's silent end, not a very quiet one.
        let master = muted || db <= Self.minGainDb ? 0 : pow(10.0, db / 20.0)

        state.sourceGainBits.store(Float(cos(angle) * master).bitPattern, ordering: .relaxed)
        synthBank.synthGain = Float(sin(angle))
        masterMixer.outputVolume = Float(master)
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

            let generation = self.state.wrapGeneration.load(ordering: .relaxed)
            guard generation != self.lastWrapGeneration else { return }

            self.lastWrapGeneration = generation

            // The current playhead, not 0: the block rewound to 0 when it wrapped, but up to 33 ms
            // have passed and a seek in that window has already moved the transport somewhere else.
            self.synthBank.scheduler.seek(toSeconds: self.playheadSeconds)
            self.synthBank.allNotesOff()
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
            var playhead = state.playheadFrames.load(ordering: .relaxed)
            if seek >= 0 { playhead = seek }

            let playing = state.playing.load(ordering: .relaxed)
            let source = state.source.pointee?.takeUnretainedValue()

            let startSeconds = Double(playhead) / rate
            var endSeconds = startSeconds
            var rendered = false

            if playing, let source, source.frameCount > 0, frames > 0 {
                let total = source.frameCount
                // One buffer behind the playhead: the MIDI for [playhead, playhead + buffer) is
                // being scheduled a cycle ahead, and this delay is what keeps the two aligned.
                let readStart = playhead - frames
                let step = (targetGain - startGain) / Float(frames)
                let outputs = min(buffers.count, 2)

                for channel in 0..<outputs {
                    guard let output = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                    else { continue }

                    // A mono take feeds both outputs.
                    let base = source.base(
                        ofChannel: min(channel, source.channelCount - 1))
                    var gain = startGain

                    for i in 0..<frames {
                        let index = readStart + i
                        let sample = index >= 0 && index < total ? base[index] : 0
                        output[i] = sample * gain
                        gain += step
                    }
                }

                playhead += frames
                endSeconds = Double(playhead) / rate
                rendered = true

                // `playhead - frames` is where this block started: once that is at or past the end,
                // every sample has been handed over and the take is done.
                if playhead - frames >= total {
                    playhead = 0
                    state.playing.store(false, ordering: .relaxed)
                    state.wrapGeneration.wrappingAdd(1, ordering: .relaxed)
                }
            }

            state.playheadFrames.store(playhead, ordering: .relaxed)

            // Every block, playing or not: a stop, a seek or a swapped note list all leave
            // note-offs to deliver and this is what delivers them.
            bank.schedule(
                from: startSeconds,
                to: endSeconds,
                renderTime: timestamp.pointee,
                frameCount: frames,
                sampleRate: rate
            )

            isSilence.pointee = ObjCBool(!rendered)

            return noErr
        }
    }
}
