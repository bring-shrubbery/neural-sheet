import CoreAudio
import CoreMIDI
import Darwin
import Foundation
import Synchronization

/// One channel's controllers as the MIDI output sends them (MIDI out design §2): the program
/// change, CC 7 from the fader and CC 10 from the pan. `channel` is 1…16, as the export counts.
nonisolated struct MidiChannelControls: Equatable, Sendable {
    var channel: Int
    var program: Int
    var volume: Int
    var pan: Int
}

/// What the sender needs to know about each program, indexed by program 0…128: its channel
/// (zero-based, -1 for none: a program the drop mode left out, or not in the take) and whether the
/// mixer lets it be heard. Written by the main thread as a whole, read by the sender.
nonisolated struct MidiOutRoutes: Sendable {
    static let programCount = 129

    var channels = [Int8](repeating: -1, count: MidiOutRoutes.programCount)
    var audible = [Bool](repeating: true, count: MidiOutRoutes.programCount)
}

/// What the main thread asks of the sender. Each is queued with the ring's write position at
/// the time, so the sender sends every note the render thread pushed before it first.
nonisolated enum MidiOutCommand: Sendable {
    /// Silence the current destination, then send to this one (0 for none).
    case setDestination(MIDIEndpointRef)
    /// CC 123 and CC 64 = 0 on every channel in use, and a note-off per sounding note.
    case panic
    case controls([MidiChannelControls])
    /// An audition: a note-on, or with velocity 0 its note-off.
    case note(program: Int, pitch: UInt8, velocity: UInt8)
}

/// The MIDI output's own thread (MIDI out design §2): woken by the render thread through a
/// semaphore, it drains ``MidiOutRing`` into timestamped `MIDIEventList`s and sends them.
///
/// Everything below `// MARK: - Sender thread` is that thread's alone -- the destination, the
/// sounding-note bit set, the event list being built -- so none of it needs a lock. The main
/// thread reaches it through ``enqueue(_:)`` and ``setRoutes(_:)``, two mutexes the render thread
/// never touches: it only pushes into the ring and signals.
nonisolated final class MidiOutSender: @unchecked Sendable {
    let ring: MidiOutRing

    private let port: MIDIPortRef

    /// `DispatchSemaphore.signal()` never blocks and does not allocate: the one call the render
    /// thread makes here besides the ring push.
    private let wake = DispatchSemaphore(value: 0)

    /// Signalled by the thread as it exits, for ``stop(waitingUpTo:)``.
    private let finished = DispatchSemaphore(value: 0)

    private let stopping = Atomic<Bool>(false)

    private let pending = Mutex<[(mark: Int, command: MidiOutCommand)]>([])

    private let routes = Mutex(MidiOutRoutes())

    private var thread: Thread?

    init(port: MIDIPortRef, ring: MidiOutRing) {
        self.port = port
        self.ring = ring

        listStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MidiOutSender.listBytes, alignment: MemoryLayout<MIDIEventList>.alignment)
    }

    deinit {
        listStorage.deallocate()
    }

    // MARK: - Any thread

    /// The render thread's wake-up, at most once per buffer.
    func signal() {
        wake.signal()
    }

    /// Main thread: queues a command behind everything already in the ring.
    func enqueue(_ command: MidiOutCommand) {
        let mark = ring.writePosition
        pending.withLock { $0.append((mark, command)) }
        wake.signal()
    }

    /// Main thread: the channel and audibility of every program, from the next wake on.
    func setRoutes(_ newRoutes: MidiOutRoutes) {
        routes.withLock { $0 = newRoutes }
    }

    /// Starts the thread, once.
    func start() {
        guard thread == nil else { return }

        let thread = Thread { [self] in
            self.run()
        }
        thread.name = "NeuralSheet MIDI out"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Lets the thread send what is queued -- a quit's panic -- and exit. Waits for it, but no
    /// longer than `seconds`: a quit must not hang on a MIDI server that has gone away.
    func stop(waitingUpTo seconds: Double) {
        guard thread != nil, !stopping.load(ordering: .relaxed) else { return }

        stopping.store(true, ordering: .releasing)
        wake.signal()
        _ = finished.wait(timeout: .now() + seconds)
    }

    // MARK: - Sender thread

    /// How large one event list may grow before it is sent and a new one begun.
    private static let listBytes = 16 * 1024

    private let listStorage: UnsafeMutableRawPointer
    private var list: UnsafeMutablePointer<MIDIEventList> { listStorage.assumingMemoryBound(to: MIDIEventList.self) }
    private var packet: UnsafeMutablePointer<MIDIEventPacket>?
    private var listTime: MIDITimeStamp = 0
    private var listCount = 0

    private var destination: MIDIEndpointRef = 0

    /// 16 channels × 128 pitches: which notes the far side has been sent an on for and no off,
    /// so a panic reaches a destination that ignores CC 123 (MIDI out design §2).
    private var sounding = [UInt64](repeating: 0, count: 32)

    /// The latest timestamp sent: a command goes out no earlier, so a panic can never arrive
    /// ahead of a note-on that was scheduled before it.
    private var lastTimestamp: MIDITimeStamp = 0

    private func run() {
        MidiOutSender.setTimeConstraintPolicy()
        begin()

        while true {
            wake.wait()

            let commands = pending.withLock { queued in
                let taken = queued
                queued.removeAll(keepingCapacity: true)
                return taken
            }
            let routes = self.routes.withLock { $0 }

            for item in commands {
                drain(before: item.mark, routes: routes)
                perform(item.command, routes: routes)
            }

            drain(before: .max, routes: routes)
            flush()

            // Only once nothing is queued: a panic queued just before the stop still goes out.
            if stopping.load(ordering: .acquiring), pending.withLock({ $0.isEmpty }) { break }
        }

        finished.signal()
    }

    /// Sends what the render thread pushed before `limit`: a note-on for an audible program, a
    /// note-off for a note that is sounding.
    private func drain(before limit: Int, routes: MidiOutRoutes) {
        while let entry = ring.pop(before: limit) {
            guard destination != 0 else { continue }

            let program = Int(entry.program)
            guard program < routes.channels.count, routes.channels[program] >= 0 else { continue }

            let channel = Int(routes.channels[program])
            let timestamp = MidiOutSender.timestamp(for: entry)

            if entry.isOn {
                guard routes.audible[program] else { continue }

                note(channel: channel, pitch: entry.pitch, velocity: entry.velocity, at: timestamp)
            } else {
                note(channel: channel, pitch: entry.pitch, velocity: 0, at: timestamp)
            }
        }
    }

    private func perform(_ command: MidiOutCommand, routes: MidiOutRoutes) {
        let now = Swift.max(mach_absolute_time(), lastTimestamp)

        switch command {
        case .setDestination(let endpoint):
            panic(routes: routes, at: now)
            flush()
            destination = endpoint

        case .panic:
            panic(routes: routes, at: now)

        case .controls(let controls):
            for control in controls {
                let channel = UInt8(Swift.min(Swift.max(control.channel, 1), 16) - 1)

                add(MidiOutSender.word(0xC0 | channel, UInt8(Swift.min(Swift.max(control.program, 0), 127)), 0), at: now)
                add(MidiOutSender.word(0xB0 | channel, 7, UInt8(Swift.min(Swift.max(control.volume, 0), 127))), at: now)
                add(MidiOutSender.word(0xB0 | channel, 10, UInt8(Swift.min(Swift.max(control.pan, 0), 127))), at: now)
            }

        case .note(let program, let pitch, let velocity):
            guard program >= 0, program < routes.channels.count, routes.channels[program] >= 0 else { return }
            guard velocity == 0 || routes.audible[program] else { return }

            note(channel: Int(routes.channels[program]), pitch: pitch, velocity: velocity, at: now)
        }
    }

    /// A note-on (velocity > 0) marks the note sounding; a note-off is only sent for one that is,
    /// so a muted program's notes, whose ons were dropped, send nothing either.
    private func note(channel: Int, pitch: UInt8, velocity: UInt8, at timestamp: MIDITimeStamp) {
        let key = Int(pitch & 0x7F)
        let word = channel * 2 + key / 64
        let bit = UInt64(1) << UInt64(key % 64)

        if velocity > 0 {
            sounding[word] |= bit
            add(MidiOutSender.word(0x90 | UInt8(channel), UInt8(key), velocity), at: timestamp)
        } else if sounding[word] & bit != 0 {
            sounding[word] &= ~bit
            add(MidiOutSender.word(0x80 | UInt8(channel), UInt8(key), 0), at: timestamp)
        }
    }

    /// CC 123 and CC 64 = 0 on every channel the routes use or a note sounds on, then a note-off
    /// for every sounding note.
    private func panic(routes: MidiOutRoutes, at timestamp: MIDITimeStamp) {
        guard destination != 0 else {
            sounding = [UInt64](repeating: 0, count: 32)
            return
        }

        var used = [Bool](repeating: false, count: 16)
        for channel in routes.channels where channel >= 0 { used[Int(channel)] = true }

        for channel in 0..<16 where used[channel] || sounding[channel * 2] | sounding[channel * 2 + 1] != 0 {
            add(MidiOutSender.word(0xB0 | UInt8(channel), 123, 0), at: timestamp)
            add(MidiOutSender.word(0xB0 | UInt8(channel), 64, 0), at: timestamp)
        }

        for channel in 0..<16 {
            for key in 0..<128 where sounding[channel * 2 + key / 64] & (UInt64(1) << UInt64(key % 64)) != 0 {
                add(MidiOutSender.word(0x80 | UInt8(channel), UInt8(key), 0), at: timestamp)
            }
        }

        sounding = [UInt64](repeating: 0, count: 32)
    }

    // MARK: - The event list

    private func begin() {
        packet = MIDIEventListInit(list, ._1_0)
        listCount = 0
    }

    /// One UMP word into the list being built. A timestamp earlier than the list's last sends the
    /// list first, so every list goes out in time order.
    private func add(_ word: UInt32, at timestamp: MIDITimeStamp) {
        if listCount > 0, timestamp < listTime { flush() }

        var word = word
        var next = packet.flatMap { MIDIEventListAdd(list, MidiOutSender.listBytes, $0, timestamp, 1, &word) }

        if next == nil {
            flush()
            next = packet.flatMap { MIDIEventListAdd(list, MidiOutSender.listBytes, $0, timestamp, 1, &word) }
        }

        guard let next else { return }

        packet = next
        listTime = timestamp
        listCount += 1
        lastTimestamp = Swift.max(lastTimestamp, timestamp)
    }

    private func flush() {
        if listCount > 0, destination != 0 {
            MIDISendEventList(port, destination, list)
        }

        begin()
    }

    // MARK: - Helpers

    /// A MIDI 1.0 channel voice message as a UMP word: message type 2, group 0.
    static func word(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> UInt32 {
        0x2000_0000 | UInt32(status) << 16 | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F)
    }

    /// When the event is heard, in `mach_absolute_time` units: the buffer's host time plus its
    /// frames at the device rate (MIDI out design §2). CoreMIDI holds a packet until then, so a
    /// sender that runs a little late is still on time.
    static func timestamp(for entry: MidiOutEntry) -> MIDITimeStamp {
        guard entry.sampleRate > 0, entry.frames > 0 else { return entry.hostTime }

        let nanos = Double(entry.frames) / entry.sampleRate * 1e9
        guard nanos.isFinite, nanos < 1e12 else { return entry.hostTime }

        return entry.hostTime &+ AudioConvertNanosToHostTime(UInt64(nanos))
    }

    /// The real-time band, as the audio threads have it: woken by the render thread, the sender
    /// should not wait behind the UI. Aperiodic, with a millisecond of work in a five-millisecond
    /// window; failing to set it leaves the thread at `.userInteractive`.
    private static func setTimeConstraintPolicy() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        let ticksPerMillisecond = timebase.numer > 0 ? 1e6 * Double(timebase.denom) / Double(timebase.numer) : 1e6

        var policy = thread_time_constraint_policy_data_t(
            period: 0,
            computation: UInt32(ticksPerMillisecond),
            constraint: UInt32(5 * ticksPerMillisecond),
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
