import Darwin
import Foundation
import Synchronization

/// The plugin's synth on its way from the synth thread to the host's render block (Audio Unit
/// design §2, "UI": the mix of host audio and the synth). A preallocated single-producer
/// single-consumer ring of stereo frames, each one the synth's sound at one position of the take's
/// timeline, in frames at the host's rate.
///
/// The consumer is the render block. Every cycle it says where the transport is: moving through
/// `[position, position + frames)` (``consume(position:frames:left:right:)``), or standing at a
/// position (``stand(at:)``). Its position after a cycle is ``ConsumerState/tail``; a cycle that
/// does not start where the last ended (a seek, a loop, the host locating, a stop somewhere else)
/// is a discontinuity, and the consumer bumps ``ConsumerState/generation``.
///
/// The producer is ``SynthRenderer``'s thread. It renders ahead of the tail and appends at
/// ``head``; when the generation moves it begins an *epoch* (``beginEpoch(anchor:generation:)``):
/// it forgets what it had, re-anchors its synth at a position ahead of the tail (``anchor(tail:moving:lead:)``,
/// so the render block finds the frames waiting rather than late) and renders on from there.
///
/// The invariant the consumer relies on: every frame in `[anchor, head)` of the epoch for the
/// consumer's current generation is the synth's sound at that position, rendered continuously
/// from the anchor with the current notes. The consumer plays what it finds there and silence
/// anywhere else, so a frame is never heard at the wrong time: at worst the synth is silent for
/// the lead after a jump.
///
/// Positions are frames on the timeline and may be negative (the host before the take); they
/// index the storage through a mask, so the capacity is a power of two. The producer writes a
/// position only below `tail + capacity`, and the consumer reads only at or above its tail, so a
/// slot is never written while it can still be read. An epoch is begun under a sequence lock:
/// the producer makes the sequence odd, writes the anchor, the head and the generation, and makes
/// it even again; the consumer takes a snapshot between two equal even reads and checks the
/// sequence again after copying.
///
/// Render thread: atomics and `memcpy`s into the caller's buffers, no allocation, no lock, no
/// Objective-C. Free of AU and AVFoundation types (design §3).
nonisolated final class SynthRing: @unchecked Sendable {
    /// What the producer reads of the consumer.
    struct ConsumerState: Equatable {
        /// Bumped at every discontinuity.
        var generation: Int
        /// Where the consumer reads next: the end of its last cycle, or where it stands.
        var tail: Int
        /// Whether the transport is moving.
        var moving: Bool
    }

    /// Frames per channel, a power of two.
    let capacityFrames: Int
    private let mask: Int

    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    // MARK: Written by the consumer

    private let tailWord = Atomic<Int>(0)
    private let generationWord = Atomic<Int>(0)
    private let movingWord = Atomic<Bool>(false)

    // MARK: Written by the producer

    /// Odd while an epoch is being begun.
    private let sequence = Atomic<Int>(0)
    private let anchorWord = Atomic<Int>(0)
    private let headWord = Atomic<Int>(0)
    /// The generation the current epoch answers; none before the first.
    private let epochWord = Atomic<Int>(Int.min)

    // MARK: The consumer's own

    private var tail = 0
    private var generation = 0

    // MARK: The producer's own

    private var producerSequence = 0
    private var producerHead = 0
    private var producerAnchor = 0

    /// A ring of at least `minimumFrames` per channel, rounded up to a power of two.
    init(minimumFrames: Int) {
        var capacity = 1
        while capacity < max(minimumFrames, 2) { capacity <<= 1 }

        capacityFrames = capacity
        mask = capacity - 1
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    // MARK: - Consumer (the render thread)

    /// The transport moves through `[position, position + frames)`: the synth's frames for it into
    /// `left` and `right`, zeros where the ring has none. Returns how many were the synth's.
    ///
    /// Render thread: a few atomic loads and stores, at most three copies and two fills per
    /// channel.
    func consume(position: Int, frames: Int, left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }

        movingWord.store(true, ordering: .relaxed)

        var found = 0

        if position == tail {
            found = copy(position: position, frames: frames, left: left, right: right)
        } else {
            discontinuity(at: position)
            fill(left, right, from: 0, to: frames)
        }

        tail = position + frames
        tailWord.store(tail, ordering: .releasing)

        return found
    }

    /// The transport stands at `position`: the producer renders ahead from there, so a start from
    /// it is heard from its first frame. Nothing is read. Render thread: two stores, three more
    /// when the position moved.
    func stand(at position: Int) {
        movingWord.store(false, ordering: .relaxed)

        if position != tail {
            discontinuity(at: position)
        }
    }

    /// The frames for `[position, position + frames)` without moving the tail: what a stop fades
    /// out over. Render thread.
    func peek(position: Int, frames: Int, left: UnsafeMutablePointer<Float>,
              right: UnsafeMutablePointer<Float>) -> Int {
        guard frames > 0 else { return 0 }

        return copy(position: position, frames: frames, left: left, right: right)
    }

    /// Where the consumer stands or reads next. Render thread.
    var consumerTail: Int { tail }

    private func discontinuity(at position: Int) {
        generation &+= 1
        tail = position
        // Moving first, then the tail, then the generation the producer acquires them with.
        tailWord.store(position, ordering: .releasing)
        generationWord.store(generation, ordering: .releasing)
    }

    /// The epoch's frames inside `[position, position + frames)`, zeros around them; 0 and zeros
    /// throughout when the epoch is not this generation's or was replaced while copying.
    private func copy(position: Int, frames: Int, left: UnsafeMutablePointer<Float>,
                      right: UnsafeMutablePointer<Float>) -> Int {
        let before = sequence.load(ordering: .acquiring)

        guard before & 1 == 0 else {
            fill(left, right, from: 0, to: frames)
            return 0
        }

        let anchor = anchorWord.load(ordering: .relaxed)
        let head = headWord.load(ordering: .acquiring)
        let epoch = epochWord.load(ordering: .relaxed)

        let lower = max(position, anchor)
        let upper = min(position + frames, head)

        guard epoch == generation, lower < upper else {
            fill(left, right, from: 0, to: frames)
            return 0
        }

        fill(left, right, from: 0, to: lower - position)
        copyOut(from: lower, count: upper - lower, into: left + (lower - position), right + (lower - position))
        fill(left, right, from: upper - position, to: frames)

        atomicMemoryFence(ordering: .acquiring)

        guard sequence.load(ordering: .relaxed) == before else {
            fill(left, right, from: 0, to: frames)
            return 0
        }

        return upper - lower
    }

    private func copyOut(from position: Int, count: Int, into left: UnsafeMutablePointer<Float>,
                         _ right: UnsafeMutablePointer<Float>) {
        let start = position & mask
        let first = min(count, capacityFrames - start)

        left.update(from: self.left + start, count: first)
        right.update(from: self.right + start, count: first)

        if count > first {
            (left + first).update(from: self.left, count: count - first)
            (right + first).update(from: self.right, count: count - first)
        }
    }

    private func fill(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, from lower: Int,
                      to upper: Int) {
        guard upper > lower else { return }

        (left + lower).update(repeating: 0, count: upper - lower)
        (right + lower).update(repeating: 0, count: upper - lower)
    }

    // MARK: - Producer (the synth thread)

    /// The consumer as of now: the generation acquired first, so the tail is at least as new.
    func consumerState() -> ConsumerState {
        let generation = generationWord.load(ordering: .acquiring)
        let tail = tailWord.load(ordering: .acquiring)
        let moving = movingWord.load(ordering: .relaxed)

        return ConsumerState(generation: generation, tail: tail, moving: moving)
    }

    /// Where the producer appends next. The producer's.
    var head: Int { producerHead }

    /// The head as last published, from any thread: what a test waits on.
    var publishedHead: Int { headWord.load(ordering: .acquiring) }

    /// Where the current epoch began.
    var anchor: Int { producerAnchor }

    /// Forgets the frames it had and starts again at `anchor` for the consumer's `generation`.
    func beginEpoch(anchor: Int, generation: Int) {
        producerSequence &+= 1
        sequence.store(producerSequence, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)

        anchorWord.store(anchor, ordering: .relaxed)
        headWord.store(anchor, ordering: .relaxed)
        epochWord.store(generation, ordering: .relaxed)
        producerAnchor = anchor
        producerHead = anchor

        producerSequence &+= 1
        sequence.store(producerSequence, ordering: .releasing)
    }

    /// Frames that may be appended now with the consumer at `tail`.
    func room(tail: Int) -> Int {
        max(0, tail + capacityFrames - producerHead)
    }

    /// Appends `frames` frames at ``head`` and publishes them. The caller has checked
    /// ``room(tail:)``; frames that do not fit are dropped.
    func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, tail: Int) {
        let count = min(frames, room(tail: tail))
        guard count > 0 else { return }

        let start = producerHead & mask
        let first = min(count, capacityFrames - start)

        (self.left + start).update(from: left, count: first)
        (self.right + start).update(from: right, count: first)

        if count > first {
            self.left.update(from: left + first, count: count - first)
            self.right.update(from: right + first, count: count - first)
        }

        producerHead += count
        headWord.store(producerHead, ordering: .releasing)
    }

    // MARK: - The producer's plan

    /// What the producer does next.
    enum Step: Equatable {
        /// Begin an epoch at this position.
        case reanchor(at: Int)
        /// Render one chunk.
        case render
        /// Nothing to do until the consumer moves on.
        case wait
    }

    /// Where an epoch begins: ahead of a moving consumer by `lead`, so its frames are ready
    /// before the consumer reaches them; at a standing consumer's position, so a start from there
    /// is heard from its first frame.
    static func anchor(tail: Int, moving: Bool, lead: Int) -> Int {
        moving ? tail + lead : tail
    }

    /// The producer's next step: a new epoch when the consumer's generation moved, when one was
    /// asked for (new notes) or when it has fallen more than half the ring behind; otherwise a
    /// chunk while it is less than `ahead` frames ahead of the tail and the chunk fits; otherwise
    /// wait. A producer a little behind renders on to catch up: faster than real time, and
    /// keeping the synth's notes continuous.
    static func nextStep(state: ConsumerState, seenGeneration: Int?, reanchorRequested: Bool, head: Int,
                         lead: Int, ahead: Int, chunk: Int, capacity: Int) -> Step {
        if state.generation != seenGeneration || reanchorRequested || state.tail - head > capacity / 2 {
            return .reanchor(at: anchor(tail: state.tail, moving: state.moving, lead: lead))
        }

        if head - state.tail < ahead, head + chunk <= state.tail + capacity {
            return .render
        }

        return .wait
    }
}
