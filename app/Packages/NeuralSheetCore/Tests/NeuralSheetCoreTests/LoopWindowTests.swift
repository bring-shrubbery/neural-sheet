import Testing

@testable import NeuralSheetCore

@Test func loopWindowNeedsAPositiveLengthInsideTheTake() {
    #expect(LoopWindow(start: 0, end: 10) != nil)
    #expect(LoopWindow(start: 10, end: 10) == nil)
    #expect(LoopWindow(start: 12, end: 10) == nil)
    #expect(LoopWindow(start: -1, end: 10) == nil)
    #expect(LoopWindow(start: 4, end: 10)?.length == 6)
}

@Test func loopWindowFromSecondsRoundsAndClampsToTheTake() {
    let window = LoopWindow(seconds: 1.0 ..< 2.5, sampleRate: 48_000, frameCount: 480_000)
    #expect(window?.start == 48_000)
    #expect(window?.end == 120_000)

    // Off the end of the take: clamped, not refused.
    let tail = LoopWindow(seconds: 9.5 ..< 12, sampleRate: 48_000, frameCount: 480_000)
    #expect(tail?.start == 456_000)
    #expect(tail?.end == 480_000)

    // Entirely past the take, or with no take, or under a frame: nothing to loop.
    #expect(LoopWindow(seconds: 11 ..< 12, sampleRate: 48_000, frameCount: 480_000) == nil)
    #expect(LoopWindow(seconds: 0 ..< 1, sampleRate: 48_000, frameCount: 0) == nil)
    #expect(LoopWindow(seconds: 1 ..< 1.000001, sampleRate: 48_000, frameCount: 480_000) == nil)
    #expect(LoopWindow(seconds: 0 ..< 1, sampleRate: 0, frameCount: 480_000) == nil)
}

@Test func wrappedFoldsPositionsPastTheEndBackIntoTheLoop() {
    let window = LoopWindow(start: 100, end: 200)!
    #expect(window.wrapped(150) == 150)
    #expect(window.wrapped(199) == 199)
    #expect(window.wrapped(200) == 100)
    #expect(window.wrapped(230) == 130)
    // A loop shorter than the overshoot folds more than once.
    #expect(window.wrapped(450) == 150)
    // Before the loop is left alone: the playhead may be playing into it.
    #expect(window.wrapped(50) == 50)
}

@Test func advanceSchedulesUpToTheEndAndLandsTheOvershootAfterTheStart() {
    let window = LoopWindow(start: 1_000, end: 2_000)!

    // Inside: nothing special.
    let inside = window.advance(from: 1_000, frames: 128)
    #expect(inside.renderEnd == 1_128)
    #expect(inside.next == 1_128)

    // Crossing: the synth stops at the end, the playhead carries the remainder past the start.
    let crossing = window.advance(from: 1_900, frames: 128)
    #expect(crossing.renderEnd == 2_000)
    #expect(crossing.next == 1_028)

    // Landing exactly on the end: the next block starts at the start.
    let exact = window.advance(from: 1_872, frames: 128)
    #expect(exact.renderEnd == 2_000)
    #expect(exact.next == 1_000)

    // Already past the end (the loop was set behind the playhead): the block plays as it was,
    // then the playhead goes to the start.
    let past = window.advance(from: 5_000, frames: 128)
    #expect(past.renderEnd == 5_128)
    #expect(past.next == 1_000)

    // Before the loop: plays into it untouched.
    let before = window.advance(from: 500, frames: 128)
    #expect(before.renderEnd == 628)
    #expect(before.next == 628)

    // Shorter than a block: the remainder folds however many times it takes.
    let short = LoopWindow(start: 10, end: 20)!
    #expect(short.advance(from: 15, frames: 128).renderEnd == 20)
    #expect(short.advance(from: 15, frames: 128).next == 13)
}

@Test func packedRoundTripsAndZeroIsNoLoop() {
    let window = LoopWindow(start: 48_000, end: 4_000_000_000)!
    #expect(LoopWindow(packed: window.packed) == window)
    #expect(LoopWindow(packed: 0) == nil)
    #expect(LoopWindow(start: 0, end: 1)?.packed != 0)
}
