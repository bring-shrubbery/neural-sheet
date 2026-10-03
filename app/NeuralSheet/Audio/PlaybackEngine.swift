import AVFoundation
import CoreAudio
import Foundation
import NeuralSheetCore
import Synchronization

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
    // Internal: PlaybackEngine+Lifecycle.swift and +Poll.swift use them.
    static let healBackoffSeconds = 0.25
    static let healBackoffMaxSeconds = 5.0
    static let healAttemptLimit = 8

    let engine = AVAudioEngine()

    /// The synth side of the graph. Its own sub-mix hangs off this, and the master fader is its
    /// output volume.
    // Internal: PlaybackEngine+Mix.swift and +Lifecycle.swift use it.
    let masterMixer = AVAudioMixerNode()

    // Internal: the extensions reach the render thread's state through it.
    let state = RenderState()

    let synthBank: InstrumentSynthBank

    // Internal: PlaybackEngine+Lifecycle.swift makes it, +Mix.swift pans it.
    var sourceNode: AVAudioSourceNode?

    /// The device rate the graph is built for.
    // Internal setter: rebuildGraph in PlaybackEngine+Lifecycle.swift writes it.
    var sampleRate: Double

    /// Strong reference to what the box points at.
    // Internal: PlaybackEngine+Transport.swift and +Source.swift use it.
    var currentSource: SourceAudio?

    /// Takes the box no longer points at, held until the render block cannot be inside them.
    // Internal: PlaybackEngine+Source.swift holds and releases them.
    var retiredSources: [SourceAudio] = []

    /// Polls ``RenderState/wrapGeneration``, so the render block never has to dispatch.
    // Internal: PlaybackEngine+Poll.swift makes it, +Lifecycle.swift cancels it.
    var wrapPoll: DispatchSourceTimer?
    // Internal: PlaybackEngine+Source.swift and +Poll.swift use it.
    var lastWrapGeneration = 0

    // Internal: PlaybackEngine+Lifecycle.swift installs and removes the meter tap.
    var meterTapInstalled = false
    var inputTapInstalled = false

    /// Guards ``rebuildGraph(_:)`` against re-entering itself.
    // Internal: PlaybackEngine+Lifecycle.swift and +Poll.swift use it.
    var isRebuilding = false

    /// When the last rebuild finished, so a graph that cannot start is not rebuilt every tick.
    // Internal: PlaybackEngine+Lifecycle.swift and +Poll.swift use it.
    var lastRebuild = Date.distantPast

    /// True between ``start()`` and ``stopEngine()``. What the health check compares the engine's
    /// actual state against.
    // Internal: PlaybackEngine+Lifecycle.swift and +Poll.swift use it.
    var shouldRun = false

    /// How long the health check waits before its next attempt, and how many it has spent. Both are
    /// reset by a successful start, by Play and by the user choosing a device.
    // Internal: PlaybackEngine+Lifecycle.swift and +Poll.swift use them.
    var healDelay = PlaybackEngine.healBackoffSeconds
    var healAttempts = 0

    /// True once the health check has spent its budget on an engine that will not start, until a
    /// fresh budget is handed out. What ``onHealExhausted`` announces.
    // Internal setter: PlaybackEngine+Poll.swift sets it, +Lifecycle.swift clears it.
    var healExhausted = false

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
    // Internal setter: written from PlaybackEngine+Lifecycle.swift.
    var lastStartError: Error?

    /// Called on the main queue when the health check gives up: eight rebuilds, backed off to five
    /// seconds apart, and the engine is still not running. Play or a device pick starts it over.
    var onHealExhausted: (() -> Void)?

    /// The status of the last I/O buffer-size request, or nil if it was accepted. The size that
    /// came back is ``ioBufferFrames``, which is what the HAL settled on rather than what was asked.
    // Internal setter: written from PlaybackEngine+Lifecycle.swift.
    var lastIOBufferError: OSStatus?

    // The HAL's device choice, aggregate and process tap are the Mac's alone
    // (`PlaybackEngine+Devices.swift`); on iOS the audio session picks the route.
    #if os(macOS)
    /// The devices the I/O units were last pointed at successfully, so a rejected switch has
    /// something to fall back to when the unit cannot name what it is on.
    var lastAppliedOutputDevice: AudioDevice?
    var lastAppliedRecordingInput: RecordingInput?

    /// The private aggregate the I/O unit is on, when the chosen devices needed one, the pair it
    /// stands for and the process tap inside it, if any. Ours to destroy -- the aggregate, then
    /// its tap -- and reused for as long as that pair does not change.
    var aggregate: Aggregate?
    #endif

    /// Set once by ``shutDown()``: from then on nothing starts the engine or makes an aggregate
    /// or a tap again.
    var isShutDown = false

    #if !os(macOS)
    /// The audio session's interruption and route-change observers and what an interruption
    /// stopped, iOS's only (`ios/NeuralSheet/Audio/PlaybackEngine+Session.swift`). Releasing it
    /// removes the observers.
    var sessionObservation: AudioSessionObservation?
    #endif

    #if os(macOS)
    /// Called on the main queue when the app a take is tapping has quit (system audio design §2),
    /// outside the HAL's listener callback. The take is the model's to end.
    var onTappedProcessExited: (() -> Void)?
    #endif

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

    #if os(macOS)
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
    #endif

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
        #if os(macOS)
        // The aggregate, then the tap in it.
        aggregate?.destroy()
        #endif
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
}
