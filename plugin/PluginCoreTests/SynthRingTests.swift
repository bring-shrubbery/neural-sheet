import Foundation
import Testing

/// Producer and consumer driven by hand on one thread: the epochs, the anchoring and the reads.

private let capacity = 64

/// The consumer's side: `frames` frames read at `position`, left channel only.
private func read(_ ring: SynthRing, at position: Int, frames: Int) -> (found: Int, left: [Float]) {
    var left = [Float](repeating: -1, count: frames)
    var right = [Float](repeating: -1, count: frames)
    let found = left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            ring.consume(position: position, frames: frames, left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    return (found, left)
}

/// The producer's side: appends the frames for `positions`, each frame holding its position
/// (left) and its negative (right).
private func produce(_ ring: SynthRing, _ positions: Range<Int>) {
    let left = positions.map { Float($0) }
    let right = positions.map { -Float($0) }
    ring.append(left: left, right: right, frames: positions.count, tail: ring.consumerState().tail)
}

/// Begins the epoch the plan asks for, as the renderer does.
private func reanchor(_ ring: SynthRing, lead: Int, seen: inout Int?) {
    let state = ring.consumerState()
    guard case let .reanchor(at) = SynthRing.nextStep(state: state, seenGeneration: seen, reanchorRequested: false,
                                                       head: ring.head, lead: lead, ahead: 32, chunk: 8,
                                                       capacity: ring.capacityFrames)
    else {
        Issue.record("expected a new epoch")
        return
    }
    seen = state.generation
    ring.beginEpoch(anchor: at, generation: state.generation)
}

@Test func capacityIsRoundedUpToAPowerOfTwo() {
    #expect(SynthRing(minimumFrames: 100).capacityFrames == 128)
    #expect(SynthRing(minimumFrames: 64).capacityFrames == 64)
}

@Test func aStandingConsumerHasTheEpochAnchoredWhereItStands() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 100)
    reanchor(ring, lead: 16, seen: &seen)
    #expect(ring.anchor == 100)

    produce(ring, 100..<120)

    // Starting from where it stood: heard from the first frame.
    let block = read(ring, at: 100, frames: 8)
    #expect(block.found == 8)
    #expect(block.left == (100..<108).map(Float.init))

    // And on, continuously, without a new epoch.
    #expect(SynthRing.nextStep(state: ring.consumerState(), seenGeneration: seen, reanchorRequested: false,
                               head: ring.head, lead: 16, ahead: 32, chunk: 8, capacity: ring.capacityFrames) == .render)
    #expect(read(ring, at: 108, frames: 8).left == (108..<116).map(Float.init))
}

@Test func aJumpIsSilentUntilTheNewEpochAndThenFromItsAnchor() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 0)
    reanchor(ring, lead: 16, seen: &seen)
    produce(ring, 0..<32)
    #expect(read(ring, at: 0, frames: 8).found == 8)

    // A seek while playing: nothing of the old epoch is heard at the new place.
    let jumped = read(ring, at: 500, frames: 8)
    #expect(jumped.found == 0)
    #expect(jumped.left == [Float](repeating: 0, count: 8))

    // The producer begins an epoch a lead ahead of where the consumer will be.
    reanchor(ring, lead: 16, seen: &seen)
    #expect(ring.anchor == 508 + 16)
    produce(ring, 524..<540)

    // Before the anchor: silence; across it: silence then the synth.
    #expect(read(ring, at: 508, frames: 8).found == 0)
    let across = read(ring, at: 516, frames: 16)
    #expect(across.found == 8)
    #expect(Array(across.left[0..<8]) == [Float](repeating: 0, count: 8))
    #expect(Array(across.left[8..<16]) == (524..<532).map(Float.init))
}

@Test func anOldEpochIsNeverHeardAfterADiscontinuity() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 0)
    reanchor(ring, lead: 16, seen: &seen)
    produce(ring, 0..<32)

    // A jump back into frames the ring still holds: they belong to the old epoch's run and are
    // refused until the producer has answered the new generation.
    _ = read(ring, at: 0, frames: 8)
    #expect(read(ring, at: 4, frames: 8).found == 0)
    #expect(read(ring, at: 12, frames: 8).found == 0)
}

@Test func aConsumerThatStopsAndStartsAgainInPlaceKeepsTheFramesAhead() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 0)
    reanchor(ring, lead: 16, seen: &seen)
    produce(ring, 0..<32)
    _ = read(ring, at: 0, frames: 8)

    // Paused at 8, the frames there are what the fade-out reads, without moving the tail.
    ring.stand(at: 8)
    var left = [Float](repeating: 0, count: 4)
    var right = [Float](repeating: 0, count: 4)
    #expect(ring.peek(position: 8, frames: 4, left: &left, right: &right) == 4)
    #expect(left == [8, 9, 10, 11])
    #expect(ring.consumerTail == 8)

    // No new epoch for a pause in place; the resume reads on.
    #expect(ring.consumerState().generation == seen)
    #expect(read(ring, at: 8, frames: 8).left == (8..<16).map(Float.init))
}

@Test func theProducerStaysWithinTheRingAndAheadTarget() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 0)
    reanchor(ring, lead: 16, seen: &seen)

    func step() -> SynthRing.Step {
        SynthRing.nextStep(state: ring.consumerState(), seenGeneration: seen, reanchorRequested: false,
                           head: ring.head, lead: 16, ahead: 32, chunk: 8, capacity: ring.capacityFrames)
    }

    while step() == .render { produce(ring, ring.head..<(ring.head + 8)) }
    #expect(ring.head == 32)
    #expect(step() == .wait)

    // A consumer reading on makes room again.
    _ = read(ring, at: 0, frames: 16)
    #expect(step() == .render)

    // New notes ask for an epoch, wherever the producer is.
    #expect(SynthRing.nextStep(state: ring.consumerState(), seenGeneration: seen, reanchorRequested: true,
                               head: ring.head, lead: 16, ahead: 32, chunk: 8,
                               capacity: ring.capacityFrames) == .reanchor(at: 16 + 16))
}

@Test func aProducerFarBehindBeginsAgainAheadOfTheConsumer() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: 0)
    reanchor(ring, lead: 16, seen: &seen)
    produce(ring, 0..<8)

    // The consumer reads on through frames that were never made: silence, but no discontinuity.
    var position = 0
    while position < 40 {
        _ = read(ring, at: position, frames: 8)
        position += 8
    }
    #expect(ring.consumerState().generation == seen)

    // Less than half the ring behind: render on to catch up.
    #expect(SynthRing.nextStep(state: ring.consumerState(), seenGeneration: seen, reanchorRequested: false,
                               head: ring.head, lead: 16, ahead: 32, chunk: 8, capacity: ring.capacityFrames) == .render)

    // More: a new epoch a lead ahead of the consumer.
    _ = read(ring, at: 40, frames: 8)
    #expect(SynthRing.nextStep(state: ring.consumerState(), seenGeneration: seen, reanchorRequested: false,
                               head: ring.head, lead: 16, ahead: 32, chunk: 8,
                               capacity: ring.capacityFrames) == .reanchor(at: 48 + 16))
}

@Test func framesWrapAroundTheStorageAndNegativePositionsWork() {
    let ring = SynthRing(minimumFrames: capacity)
    var seen: Int?

    ring.stand(at: -20)
    reanchor(ring, lead: 16, seen: &seen)

    var position = -20
    for _ in 0..<40 {
        produce(ring, ring.head..<(ring.head + 8))
        let block = read(ring, at: position, frames: 8)
        #expect(block.found == 8)
        #expect(block.left == (position..<(position + 8)).map(Float.init))
        position += 8
    }
}
