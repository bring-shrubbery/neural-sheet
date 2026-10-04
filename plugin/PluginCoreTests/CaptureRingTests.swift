import CoreAudio
import Foundation
import Synchronization
import Testing

@Test func drainReturnsNothingWhileNothingWasPushed() {
    let ring = CaptureRing(capacityFrames: 16, channels: 2)
    #expect(ring.drain().isEmpty)
    #expect(ring.pendingFrames == 0)
    #expect(ring.drain().isEmpty)
}

@Test func drainReturnsThePushedFramesInOrderAndThenNothing() {
    let ring = CaptureRing(capacityFrames: 64, channels: 2)

    #expect(push(ring, from: 0, frames: 5))
    #expect(push(ring, from: 5, frames: 7))
    #expect(ring.pendingFrames == 12)

    let drained = ring.drain()
    #expect(drained.count == 2)
    #expect(drained[0] == numbered(0..<12))
    #expect(drained[1] == numbered(0..<12, sign: -1))
    #expect(ring.drain().isEmpty)

    #expect(push(ring, from: 12, frames: 3))
    #expect(ring.drain()[0] == numbered(12..<15))
}

@Test func framesWrapAroundTheEndOfTheStorage() {
    let ring = CaptureRing(capacityFrames: 10, channels: 2)

    // 0..<7 in and out, then 7..<15 lands across the end: 3 at the tail, 5 at the start.
    #expect(push(ring, from: 0, frames: 7))
    #expect(ring.drain()[0] == numbered(0..<7))
    #expect(push(ring, from: 7, frames: 8))

    let drained = ring.drain()
    #expect(drained[0] == numbered(7..<15))
    #expect(drained[1] == numbered(7..<15, sign: -1))

    // Many laps, in blocks that do not divide the capacity.
    var next = 15
    for _ in 0..<20 {
        #expect(push(ring, from: next, frames: 3))
        #expect(push(ring, from: next + 3, frames: 4))
        #expect(ring.drain()[0] == numbered(next..<(next + 7)))
        next += 7
    }
    #expect(ring.overflowFrames.load(ordering: .relaxed) == 0)
}

@Test func aFullRingDropsTheWholeBlockCountsItAndKeepsWhatItHad() {
    let ring = CaptureRing(capacityFrames: 10, channels: 2)

    #expect(push(ring, from: 0, frames: 8))
    // Three more do not fit in the two left: dropped whole, never partly written.
    #expect(!push(ring, from: 100, frames: 3))
    #expect(ring.overflowFrames.load(ordering: .relaxed) == 3)
    // Two do.
    #expect(push(ring, from: 8, frames: 2))
    #expect(!push(ring, from: 100, frames: 1))
    #expect(ring.overflowFrames.load(ordering: .relaxed) == 4)

    #expect(ring.drain()[0] == numbered(0..<10))

    // Drained, it takes frames again.
    #expect(push(ring, from: 10, frames: 10))
    #expect(ring.drain()[0] == numbered(10..<20))
}

@Test func aChannelTheHostDidNotSupplyIsSilence() {
    let ring = CaptureRing(capacityFrames: 8, channels: 2)

    #expect(push(ring, from: 1, frames: 4, channels: 1))

    let drained = ring.drain()
    #expect(drained[0] == numbered(1..<5))
    #expect(drained[1] == [0, 0, 0, 0])
}

@Test func prepareForCaptureDropsLeftoversAndForgetsTheStartTime() {
    let ring = CaptureRing(capacityFrames: 8, channels: 2)

    ring.noteStart(sampleTime: 1234)
    ring.noteStart(sampleTime: 9999)
    #expect(push(ring, from: 0, frames: 3))
    #expect(ring.firstSampleTime == 1234)

    ring.prepareForCapture()
    #expect(ring.drain().isEmpty)
    #expect(ring.firstSampleTime == nil)

    ring.noteStart(sampleTime: 512)
    #expect(push(ring, from: 3, frames: 2))
    #expect(ring.drain()[0] == numbered(3..<5))
    #expect(ring.firstSampleTime == 512)

    ring.releaseMemory()
    ring.prepareForCapture()
    #expect(push(ring, from: 5, frames: 8))
    #expect(ring.drain()[1] == numbered(5..<13, sign: -1))
}

@Test func theRingIsSizedForTenMinutesAtTheHostRate() {
    #expect(CaptureRing.capacityFrames(for: 48000) == 28_800_000)
    #expect(CaptureRing.capacityFrames(for: 44100) == 26_460_000)
}

private nonisolated final class Flag: Sendable {
    let value = Atomic<Bool>(false)
}

/// The render thread and the main thread at once: everything pushed comes out, in order, exactly
/// once; a block the ring turned away is counted and retried, as a later block would follow it.
@Test func aConcurrentProducerAndConsumerLoseNothing() {
    let ring = CaptureRing(capacityFrames: 1000, channels: 2)
    let total = 200_000
    let frames = 37
    let done = Flag()

    let producer = Thread {
        var next = 0
        while next < total {
            let count = min(frames, total - next)
            if push(ring, from: next, frames: count) { next += count }
        }
        done.value.store(true, ordering: .releasing)
    }
    producer.start()

    var received: [Float] = []
    received.reserveCapacity(total)
    while !done.value.load(ordering: .acquiring) {
        if let channel = ring.drain().first { received.append(contentsOf: channel) }
    }
    if let channel = ring.drain().first { received.append(contentsOf: channel) }

    #expect(received == numbered(0..<total))
}
