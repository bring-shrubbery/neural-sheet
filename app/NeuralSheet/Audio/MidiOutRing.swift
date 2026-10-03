import Foundation
import Synchronization

/// One note on its way from the render thread to the MIDI sender: the scheduler's event and when
/// the buffer it belongs to is heard (MIDI out design §2).
///
/// The timing stays in the render thread's own terms -- the buffer's host time, the frames from
/// it and the rate they count at -- and the sender does the conversion, so the render thread's
/// share is a handful of stores.
nonisolated struct MidiOutEntry: Equatable, Sendable {
    /// `mHostTime` of the render cycle, `mach_absolute_time` ticks.
    var hostTime: UInt64 = 0
    /// Output frames from `hostTime` to the event: the buffer of lead the synths are scheduled
    /// with, then the event's offset into the block.
    var frames: Int32 = 0
    /// The device rate the frames count at.
    var sampleRate: Double = 0
    var program: UInt8 = 0
    var pitch: UInt8 = 0
    /// 1…127 for a note-on, 0 for a note-off.
    var velocity: UInt8 = 0
    var isOn = false
}

/// A fixed single-producer single-consumer ring of ``MidiOutEntry`` (MIDI out design §2): the
/// render thread pushes, the sender thread pops, and neither ever waits for the other.
///
/// `head` and `tail` count forever (an `Int` does not wrap in the lifetime of a session) and
/// index the storage through a mask. The producer writes the slot, then publishes it with a
/// releasing store of `head`; the consumer acquires `head` before reading the slot and releases
/// `tail` after, which is what lets the producer reuse it. A full ring drops the event and counts
/// it rather than blocking: losing a note under a flood is better than a render thread waiting on
/// another thread.
nonisolated final class MidiOutRing: @unchecked Sendable {
    /// A power of two, for the mask. More than the most one block can produce
    /// (``NoteScheduler/reservedEventCapacity``, 2 560), so even a pathological block fits while
    /// the sender is still draining the one before it.
    static let capacity = 4096

    private let storage: UnsafeMutablePointer<MidiOutEntry>
    private let mask = MidiOutRing.capacity - 1

    /// Written by the producer only.
    private let head = Atomic<Int>(0)

    /// Written by the consumer only.
    private let tail = Atomic<Int>(0)

    /// Events a full ring turned away, for the debug log.
    let dropped = Atomic<Int>(0)

    init() {
        storage = UnsafeMutablePointer<MidiOutEntry>.allocate(capacity: MidiOutRing.capacity)
        storage.initialize(repeating: MidiOutEntry(), count: MidiOutRing.capacity)
    }

    deinit {
        storage.deinitialize(count: MidiOutRing.capacity)
        storage.deallocate()
    }

    /// Producer (the render thread): one slot written and one releasing store. No allocation, no
    /// lock. False when the ring was full and the event was dropped.
    @discardableResult
    func push(_ entry: MidiOutEntry) -> Bool {
        let position = head.load(ordering: .relaxed)

        guard position - tail.load(ordering: .acquiring) < MidiOutRing.capacity else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        storage[position & mask] = entry
        head.store(position &+ 1, ordering: .releasing)

        return true
    }

    /// Consumer (the sender thread): the oldest entry, or nil when the ring is empty or the next
    /// entry is at or past `limit`, a ``writePosition`` read earlier.
    func pop(before limit: Int = .max) -> MidiOutEntry? {
        let position = tail.load(ordering: .relaxed)

        guard position < limit, position < head.load(ordering: .acquiring) else { return nil }

        let entry = storage[position & mask]
        tail.store(position &+ 1, ordering: .releasing)

        return entry
    }

    /// How many entries have ever been pushed: what a command from the main thread is ordered
    /// after, so the sender sends everything pushed before it first.
    var writePosition: Int { head.load(ordering: .acquiring) }
}
