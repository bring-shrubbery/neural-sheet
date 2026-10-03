import AVFoundation
import Darwin
import Foundation
import NeuralSheetCore
import Synchronization

/// The host time the take's first sample belongs to: written once by the render thread when the
/// click's clock reaches the count-in's end, read by the recorder's tap to cut its first buffer
/// there (click design §2). One word, 0 for "not reached yet".
nonisolated final class DownbeatMark: @unchecked Sendable {
    private let bits = Atomic<UInt64>(0)

    /// The downbeat's host time, or nil until the render thread has reached it.
    var hostTime: UInt64? {
        let value = bits.load(ordering: .acquiring)

        return value == 0 ? nil : value
    }

    /// Render thread: one store.
    func set(_ hostTime: UInt64) {
        bits.store(Swift.max(hostTime, 1), ordering: .releasing)
    }

    /// Main thread, before a recorder is armed against it.
    func reset() {
        bits.store(0, ordering: .releasing)
    }
}

/// Everything of the click the render thread touches (click design §3), so the bank's own table
/// and event buffer stay as they were: its scheduler, its event buffer, the enabled switch, and the
/// free-running clock a count-in and a recording run on.
///
/// The clock exists because there is no transport while a take is counted in or recorded -- the
/// state is `.countingIn` or `.recording`, there is no take to play, and the transport's
/// `t0 == t1` -- yet the click has to keep time. While ``freeRun`` is set the click's block times
/// come from this clock, advanced by the block's frames at the device rate, instead of the
/// transport's; the design's silent source of N bars would have stopped the transport at its end,
/// leaving nothing to carry the click on through the take.
nonisolated final class ClickRenderState: @unchecked Sendable {
    /// What an unset request reads as: a NaN bit pattern no `Double` the main thread writes has.
    static let none = UInt64.max

    let scheduler = NoteScheduler()

    /// The click's own event buffer, reserved like the bank's so `collect` never grows it.
    var events: [SynthEvent] = []

    /// `ClickTrack.program`, copied into an instance constant so the render path reads a stored
    /// word rather than a lazily-initialised global.
    let program = ClickTrack.program

    /// Read once per render call: false advances the click's scheduler and drops what it
    /// collected, so turning it on mid-bar lands in time.
    let enabled = Atomic<Bool>(false)

    /// True while the click runs on ``clock`` rather than the transport.
    let freeRun = Atomic<Bool>(false)

    /// A position for ``clock`` to jump to on the next block, or ``none``.
    let clockRequest = Atomic<UInt64>(ClickRenderState.none)

    /// Render thread only: the free-running clock, in seconds.
    var clock = 0.0

    /// ``clock`` at the end of the last block, published for the main thread's count.
    let clockBits = Atomic<UInt64>(0)

    /// The clock time to record the host time of in ``mark``, or ``none``.
    let markTargetBits = Atomic<UInt64>(ClickRenderState.none)

    let mark = DownbeatMark()

    /// `mach_absolute_time` ticks per second, worked out once here rather than on the render thread.
    let hostTicksPerSecond: Double

    init() {
        events.reserveCapacity(NoteScheduler.reservedEventCapacity)

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        hostTicksPerSecond = timebase.numer > 0 ? 1e9 * Double(timebase.denom) / Double(timebase.numer) : 1e9
    }

    // MARK: - Render thread

    /// The click's span for this block: the transport's, or the free-running clock's while it is
    /// set, with the rate its offsets are counted at. Atomics and plain arithmetic only.
    func span(t0: Double, t1: Double, frameCount: Int, sampleRate: Double, outputRate: Double)
        -> (start: Double, end: Double, rate: Double)
    {
        // Acquiring, paired with the main thread's releasing store, so a request written before
        // the switch is seen with it.
        guard freeRun.load(ordering: .acquiring) else { return (t0, t1, sampleRate) }

        let request = clockRequest.exchange(ClickRenderState.none, ordering: .relaxed)
        if request != ClickRenderState.none { clock = Double(bitPattern: request) }

        let rate = outputRate > 0 ? outputRate : sampleRate
        let start = clock
        let end = rate > 0 ? start + Double(Swift.max(frameCount, 0)) / rate : start

        clock = end
        clockBits.store(end.bitPattern, ordering: .relaxed)

        return (start, end, rate)
    }

    /// When the block reaches the marked clock time, works out the host time it will be heard at
    /// -- the same one buffer ahead the events are scheduled at -- and publishes it once.
    func markIfReached(start: Double, end: Double, rate: Double, renderTime: AudioTimeStamp, frameCount: Int,
                       outputRate: Double) {
        let targetBits = markTargetBits.load(ordering: .relaxed)
        guard targetBits != ClickRenderState.none, outputRate > 0 else { return }

        let target = Double(bitPattern: targetBits)
        guard target < end else { return }

        // Output frames from this cycle's first sample: the buffer of lead, then the offset into
        // the block. A target already behind the block (a late first block) is its start.
        let frames = Double(Swift.max(frameCount, 0)) + Swift.max(0, target - start) * rate
        let seconds = frames / outputRate
        // `UInt64(_:)` traps on a non-finite value; a nonsense rate is the block's own start.
        let ticks = seconds.isFinite ? UInt64(Swift.min(Swift.max(0, seconds * hostTicksPerSecond), 1e15)) : 0
        let anchor = renderTime.mFlags.contains(.hostTimeValid) ? renderTime.mHostTime : mach_absolute_time()

        // Only the first block to get here publishes; a main thread that has re-armed meanwhile
        // keeps its own target.
        if markTargetBits.compareExchange(expected: targetBits, desired: ClickRenderState.none, ordering: .relaxed)
            .exchanged
        {
            mark.set(anchor &+ ticks)
        }
    }
}

/// The click's synth and the main thread's side of its state (click design §2). The synth plays
/// program `ClickTrack.program` on the percussion channel: outside the sub-mix, so the crossfade,
/// the solos and the meters never touch it; into the master mixer, so the output level and MUTE do.
nonisolated extension InstrumentSynthBank {
    // MARK: - Synth

    /// Creates the click's synth once, at `init`. Main thread.
    func ensureClickInstrument() {
        guard clickInstrument == nil, let node = makeSynthNode() else { return }

        engine.attach(node)
        engine.connect(node, to: mixTarget, format: renderFormat)

        loadCurrentSoundBank(into: node)
        sendProgramChange(to: node, program: click.program)

        let instrument = SynthInstrument(
            program: click.program, node: node, bus: 0, sampleRate: renderRate, scratchFrames: 1)
        instrument.gain = Float(InstrumentSynthBank.linearGain(db: ProjectState.defaultClickGainDb))
        instrument.scheduleBlock = node.auAudioUnit.scheduleMIDIEventBlock
        node.volume = instrument.gain

        clickInstrument = instrument

        // Last, as for the instruments: the render thread only sees a block whose node is in the
        // graph.
        blocks[click.program] = instrument.scheduleBlock
    }

    /// The click's half of ``reconnectForCurrentRate()``.
    func reconnectClickForCurrentRate() {
        guard let instrument = clickInstrument else { return }

        engine.disconnectNodeOutput(instrument.node)
        engine.connect(instrument.node, to: mixTarget, format: renderFormat)
        instrument.node.volume = instrument.gain
        sendProgramChange(to: instrument.node, program: instrument.program)
    }

    // MARK: - Switches

    /// Whether the click is heard. One atomic store; the render block reads it once per call.
    var clickEnabled: Bool {
        get { click.enabled.load(ordering: .relaxed) }
        set { click.enabled.store(newValue, ordering: .relaxed) }
    }

    /// The click's fader, −36 (silence) … +6 dB: its node's volume on the master mixer.
    func setClickGain(db: Double) {
        guard let instrument = clickInstrument else { return }

        instrument.gain = Float(InstrumentSynthBank.linearGain(db: db))
        instrument.node.volume = instrument.gain
    }

    /// What the click plays: the project's beats, or a recording's count-in and take. Main thread;
    /// the scheduler's own swap, so the render thread picks it up with its grace period.
    func setClickEvents(_ notes: [NoteEvent]) {
        click.scheduler.swap(notes: notes)
    }

    // MARK: - Free-running clock

    /// The host time the take starts at, once the clock has reached it.
    var downbeat: DownbeatMark { click.mark }

    /// Clears the mark, before a recorder is armed against it, so a stale one from the last take
    /// cannot start the next one at once.
    func resetDownbeat() {
        click.markTargetBits.store(ClickRenderState.none, ordering: .relaxed)
        click.mark.reset()
    }

    /// Runs the click on its own clock from 0, and marks the host time at which it reaches
    /// `downbeatSeconds` (click design §2). Main thread.
    func startClickClock(downbeatSeconds: Double) {
        click.mark.reset()
        click.markTargetBits.store(downbeatSeconds.bitPattern, ordering: .relaxed)
        click.clockRequest.store(Double(0).bitPattern, ordering: .relaxed)
        click.clockBits.store(Double(0).bitPattern, ordering: .relaxed)
        // Releasing: the render thread that sees the switch sees the requests above with it.
        click.freeRun.store(true, ordering: .releasing)
    }

    /// Back to the transport's time. Main thread.
    func stopClickClock() {
        click.freeRun.store(false, ordering: .releasing)
        click.markTargetBits.store(ClickRenderState.none, ordering: .relaxed)
        click.scheduler.requestAllNotesOff()
    }

    /// Where the free-running clock is, as of the last block.
    var clickClockSeconds: Double { Double(bitPattern: click.clockBits.load(ordering: .relaxed)) }

    // MARK: - Render thread

    /// The click's share of a render call: its span, its events, its mark, and -- only when it is
    /// enabled -- the events to its synth. No allocation (the buffer is reserved, the scheduler's
    /// own contract), no lock, no lookup: the block is at ``ClickRenderState/program`` in the same
    /// fixed table.
    func scheduleClick(
        from t0: Double, to t1: Double, renderTime: AudioTimeStamp, frameCount: Int, sampleRate: Double,
        outputRate: Double, base: AUEventSampleTime
    ) {
        let click = self.click
        let span = click.span(t0: t0, t1: t1, frameCount: frameCount, sampleRate: sampleRate, outputRate: outputRate)

        click.scheduler.collect(from: span.start, to: span.end, sampleRate: span.rate, into: &click.events)
        click.markIfReached(start: span.start, end: span.end, rate: span.rate, renderTime: renderTime,
                            frameCount: frameCount, outputRate: outputRate)

        guard click.enabled.load(ordering: .relaxed) else { return }

        send(click.events, base: base)
    }
}
