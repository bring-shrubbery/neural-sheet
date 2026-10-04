import Foundation
import NeuralSheetCore
import Synchronization

/// The plugin's playback state between the main thread and the render block (Audio Unit design §2,
/// "Playhead" and the mix): whose transport moves the take's timeline this cycle, where it is,
/// the take the plugin's own transport plays, and the mix's gains.
///
/// Whose transport: while the host plays and the take has a start on the host's clock, the host's
/// -- the timeline position is the cycle's `mSampleTime` minus the take's first sample time. While
/// the host is stopped, the plugin's own (Play / Pause / Go to start in the view): the render block
/// advances ``ownPosition`` and the output plays the take from its buffer in place of the host's
/// input, so the take can be auditioned without the host. The host playing takes over at once; when
/// it stops, the plugin's transport stands where the host stopped.
///
/// Whether the host plays is the main thread's 30 Hz poll of `transportStateBlock`, stored in
/// ``hostPlaying``; the render block never calls the block.
///
/// Every field is a single-word atomic. The take arrives as an unretained pointer in one word,
/// kept alive by ``currentTake`` and, after a swap, for a grace period, as the app's playback
/// engine keeps a replaced take. Free of AU types (design §3).
nonisolated final class PluginTransport: @unchecked Sendable {
    enum Mode: UInt8, Equatable {
        /// Nothing moves: the host's input passes through.
        case idle = 0
        /// The host plays and the timeline follows its sample time.
        case host = 1
        /// The plugin's own transport plays the take.
        case own = 2
    }

    // MARK: - Main thread → render block

    /// The poll's answer to whether the host's transport moves.
    let hostPlaying = Atomic<Bool>(false)

    /// Play / Pause of the plugin's own transport. The render block clears it at the take's end.
    let ownPlaying = Atomic<Bool>(false)

    /// A position for the plugin's own transport the render block has not applied yet, -1 for
    /// none.
    let pendingSeek = Atomic<Int>(-1)

    /// The mix (``MixLaw/Gains``) as `Float` bit patterns: the source's, the master folded in; the
    /// synth's crossfade side; the master.
    let sourceGainBits = Atomic<UInt32>(Float(1).bitPattern)
    let synthGainBits = Atomic<UInt32>(Float(0).bitPattern)
    let masterGainBits = Atomic<UInt32>(Float(1).bitPattern)

    /// The take's first sample on the host's clock as a bit pattern, ``noStart`` for none.
    private let hostStartBits = Atomic<UInt64>(PluginTransport.noStart)
    private static let noStart = UInt64.max

    private let takeSlot = Atomic<Unmanaged<SourceAudio>?>(nil)

    // MARK: - Render block → main thread

    /// The plugin's own transport, in take frames. Written by the render block only; the main
    /// thread moves it through ``pendingSeek``.
    let ownPosition = Atomic<Int>(0)

    /// The timeline position of the last cycle's first frame, and whose transport it was.
    let position = Atomic<Int>(0)
    let modeWord = Atomic<UInt8>(Mode.idle.rawValue)

    // MARK: - The main thread's

    /// What ``takeSlot`` points at.
    private var currentTake: SourceAudio?

    /// Takes the slot no longer points at, until the render block cannot be reading them.
    private var retiredTakes: [SourceAudio] = []

    private static let retirementSeconds = 0.5

    init() {}

    deinit {
        takeSlot.store(nil, ordering: .relaxed)
    }

    // MARK: - Main thread

    /// The take the plugin's transport plays, at the host's rate, and its first frame on the
    /// host's clock; nil for none. Stops the plugin's transport at its start.
    func setTake(_ take: SourceAudio?, startSampleTime: Double?) {
        ownPlaying.store(false, ordering: .relaxed)
        pendingSeek.store(0, ordering: .relaxed)
        hostStartBits.store(startSampleTime?.bitPattern ?? Self.noStart, ordering: .relaxed)

        let retiring = currentTake
        currentTake = take
        takeSlot.store(take.map { Unmanaged.passUnretained($0) }, ordering: .releasing)

        guard let retiring else { return }

        retiredTakes.append(retiring)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retirementSeconds) { [weak self] in
            guard let self, let index = self.retiredTakes.firstIndex(where: { $0 === retiring }) else { return }
            self.retiredTakes.remove(at: index)
        }
    }

    var take: SourceAudio? { currentTake }

    func setGains(_ gains: MixLaw.Gains) {
        sourceGainBits.store(gains.source.bitPattern, ordering: .relaxed)
        synthGainBits.store(gains.synth.bitPattern, ordering: .relaxed)
        masterGainBits.store(gains.master.bitPattern, ordering: .relaxed)
    }

    /// The plugin's own transport moves the timeline only while the host is stopped.
    func play() {
        guard currentTake != nil else { return }
        ownPlaying.store(true, ordering: .relaxed)
    }

    func pause() {
        ownPlaying.store(false, ordering: .relaxed)
    }

    /// Moves the plugin's own transport to `frame`, clamped into the take.
    func seek(toFrame frame: Int) {
        let limit = currentTake?.frameCount ?? 0
        pendingSeek.store(min(max(frame, 0), max(limit - 1, 0)), ordering: .relaxed)
    }

    var mode: Mode { Mode(rawValue: modeWord.load(ordering: .relaxed)) ?? .idle }

    /// Where the roll's playhead is, in frames on the take's timeline: the host's position while
    /// it plays, the plugin's own transport otherwise (a seek not yet applied counts).
    var playheadFrame: Int {
        if mode == .host { return position.load(ordering: .relaxed) }

        let seek = pendingSeek.load(ordering: .relaxed)
        return seek >= 0 ? seek : ownPosition.load(ordering: .relaxed)
    }

    // MARK: - Render block

    /// The take's first sample on the host's clock, nil for none.
    var hostStart: Double? {
        let bits = hostStartBits.load(ordering: .relaxed)
        return bits == Self.noStart ? nil : Double(bitPattern: bits)
    }

    /// Calls `body` with the take the plugin's transport plays, borrowed for the cycle without a
    /// retain, or with nil. Not generic, so the render block never asks the runtime for metadata.
    @inline(__always)
    func withTake(_ body: (SourceAudio?) -> Void) {
        guard let take = takeSlot.load(ordering: .acquiring) else {
            body(nil)
            return
        }
        take._withUnsafeGuaranteedRef { body($0) }
    }

    /// One cycle's decision.
    struct Cycle: Equatable {
        var mode: Mode
        /// The timeline position of the cycle's first frame.
        var position: Int
        /// The plugin's own transport after the cycle.
        var ownPosition: Int
        /// The plugin's own transport ran off the take's end this cycle: it stops, at the start.
        var ownFinished: Bool
    }

    /// Whose transport moves the timeline through this cycle of `frames` frames, and where.
    ///
    /// `sampleTime` is the cycle's `mSampleTime` when valid; `lastMode` and `lastHostEnd` the
    /// render block's memory of the cycle before (the host's position after it), so the plugin's
    /// transport stands where the host stopped. Pure.
    static func cycle(hostPlaying: Bool, hostStart: Double?, sampleTime: Double?, ownPlaying: Bool, ownPosition: Int,
                      takeFrames: Int, frames: Int, lastMode: Mode, lastHostEnd: Int) -> Cycle {
        if hostPlaying, let hostStart, let sampleTime {
            let offset = (sampleTime - hostStart).rounded()
            let position = offset.isFinite && abs(offset) < 1e15 ? Int(offset) : 0
            return Cycle(mode: .host, position: position, ownPosition: ownPosition, ownFinished: false)
        }

        var own = ownPosition

        // The host has just stopped (or lost its clock): the plugin's transport stands where it
        // did, inside the take.
        if lastMode == .host {
            own = lastHostEnd >= 0 && lastHostEnd < takeFrames ? lastHostEnd : 0
        }

        // The plugin's transport plays only while the host is stopped.
        guard ownPlaying, !hostPlaying, takeFrames > 0 else {
            return Cycle(mode: .idle, position: own, ownPosition: own, ownFinished: false)
        }

        let next = own + max(frames, 0)

        if next >= takeFrames {
            return Cycle(mode: .own, position: own, ownPosition: 0, ownFinished: true)
        }

        return Cycle(mode: .own, position: own, ownPosition: next, ownFinished: false)
    }
}
