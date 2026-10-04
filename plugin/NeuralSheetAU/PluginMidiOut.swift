import AudioToolbox
import Darwin
import Foundation
import NeuralSheetCore
import Synchronization
import os

/// *Send MIDI to host* (Audio Unit design §2, "MIDI to host"): the transcription on a virtual
/// CoreMIDI source, "NeuralSheet Plugin", which a host's MIDI track records from in time with its
/// transport. The app's MIDI out does the sending -- the same ``MidiOutRing``, sender thread,
/// channel map, controllers and panic, publishing on a source of its own
/// (``MidiOutput/init(virtualSourceNamed:)``).
///
/// The notes are scheduled in the host's own render cycle, not on the synth's thread, which
/// renders ahead on a clock of its own: the render block collects the cycle's stretch of the
/// timeline from a second ``NoteScheduler`` and pushes each event with the cycle's `mHostTime`
/// and its frame offset, as the app's render thread pushes them with its buffer's. A jump in the
/// timeline (the host locating) releases and re-attacks through the scheduler itself; a stop asks
/// it for every note-off, and the main thread's ``panic()`` follows.
///
/// The source is made the first time sending is turned on, so a unit nobody asks for MIDI -- every
/// auval pass -- makes no CoreMIDI client. Threading: ``render(from:to:stopping:timestamp:frames:sampleRate:)``
/// is the render thread's and touches only the scheduler, ``events`` and the output's atomics and
/// ring, borrowed through one word; everything else is the main thread's.
nonisolated final class PluginMidiOut: @unchecked Sendable {
    static let sourceName = "NeuralSheet Plugin"

    /// The same notes as the synth, collected at the host's cycle.
    let scheduler = NoteScheduler()

    /// Render thread only; reserved to the most one block can produce, so collecting never grows
    /// it.
    private var events: [SynthEvent] = []

    /// The output, once made, as one word the render block borrows; set once and never cleared
    /// while the unit lives.
    private let slot = Atomic<Unmanaged<MidiOutput>?>(nil)

    // MARK: - The main thread's

    private var output: MidiOutput?
    private var notes: [NoteEvent] = []
    private var mixer = InstrumentMixerState()
    private var mode = MidiOverflowMode.reuseChannels

    init() {
        events.reserveCapacity(NoteScheduler.reservedEventCapacity)
    }

    // MARK: - Main thread

    /// Whether the transcription is being sent.
    var isSending: Bool { output?.isSending ?? false }

    /// Sends from now on, or stops; turning it off silences everything sounding first. False when
    /// the source could not be made, which leaves sending off.
    @discardableResult
    func setSending(_ sending: Bool) -> Bool {
        guard sending else {
            output?.setSourceEnabled(false)
            scheduler.requestAllNotesOff()
            return true
        }

        if output == nil {
            let made = MidiOutput(virtualSourceNamed: Self.sourceName)

            guard made.hasVirtualSource else {
                made.shutDown()
                PluginLog.logger.error("midi: the virtual source could not be made")
                return false
            }

            output = made
            slot.store(Unmanaged.passUnretained(made), ordering: .releasing)
            refreshRoutes()
        }

        // What covers the playhead is attacked again at the next moving cycle.
        scheduler.requestAllNotesOff()
        output?.setSourceEnabled(true)
        return true
    }

    /// The notes from now on, and the channel map and controllers they and the strips give.
    func setNotes(_ notes: [NoteEvent], mixer: InstrumentMixerState) {
        self.notes = notes.filter { (0...NoteEvent.drumProgram).contains($0.program) }
        self.mixer = mixer
        scheduler.swap(notes: self.notes)
        refreshRoutes()
    }

    /// The strips: a muted or soloed-out instrument's notes are not sent, a fader moves CC 7.
    func setMixer(_ mixer: InstrumentMixerState) {
        self.mixer = mixer
        refreshRoutes()
    }

    /// How a transcription with more instruments than channels is mapped, as the app's setting.
    func setOverflowMode(_ mode: MidiOverflowMode) {
        guard mode != self.mode else { return }

        self.mode = mode
        refreshRoutes()
    }

    /// All notes off, after everything already pushed: for a stop, a seek, the host starting or
    /// stopping, and the render resources going.
    func panic() {
        scheduler.requestAllNotesOff()
        output?.panic()
    }

    /// The unit is going: everything sounding is silenced, the sender stopped, the source and the
    /// client disposed.
    func shutDown() {
        output?.shutDown()
    }

    private func refreshRoutes() {
        output?.setRoutes(channels: MidiChannelMap.assign(notes: notes, mode: mode), mixer: mixer)
    }

    // MARK: - Render thread

    /// The cycle's events in `[t0, t1)` (seconds on the take's timeline; `t1 == t0` while the
    /// transport stands), pushed with the cycle's host time and their frames from it. `stopping`
    /// on the cycle the transport stops: everything sounding gets its note-off.
    ///
    /// One acquiring load and one relaxed load while nothing is sent. Otherwise the scheduler's
    /// collect (allocation- and lock-free, into the reserved ``events``), a few stores and one
    /// releasing store per event and one semaphore signal: no allocation, no lock, no CoreMIDI
    /// call, no Objective-C.
    func render(from t0: Double, to t1: Double, stopping: Bool, timestamp: UnsafePointer<AudioTimeStamp>,
                frames: Int, sampleRate: Double) {
        guard let output = slot.load(ordering: .acquiring) else { return }

        output._withUnsafeGuaranteedRef { output in
            guard output.sending.load(ordering: .relaxed) else { return }

            if stopping { scheduler.requestAllNotesOff() }

            scheduler.collect(from: t0, to: t1, sampleRate: sampleRate, into: &events)

            guard !events.isEmpty else { return }

            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
            let ring = output.ring
            var pushed = false

            events.withUnsafeBufferPointer { collected in
                for event in collected where event.program >= 0 && event.program <= NoteEvent.drumProgram {
                    let entry = MidiOutEntry(
                        hostTime: hostTime,
                        frames: Int32(clamping: Swift.min(Swift.max(event.sampleOffset, 0), frames)),
                        sampleRate: sampleRate,
                        program: UInt8(event.program),
                        pitch: UInt8(Swift.min(Swift.max(event.pitch, 0), 127)),
                        velocity: event.isOn ? event.velocity : 0,
                        isOn: event.isOn)

                    if ring.push(entry) { pushed = true }
                }
            }

            if pushed { output.signal() }
        }
    }
}
