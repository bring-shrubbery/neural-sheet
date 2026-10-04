import Foundation
import NeuralSheetCore
import Synchronization
import Testing

/// The host as the session sees it: a ring the unit allocated, a transport the test moves, and
/// render cycles that do what the render block does.
@MainActor private final class FakeHost {
    var ring: CaptureRing? = CaptureRing(capacityFrames: 48_000, channels: 2, sampleRate: 48_000)
    var playing: Bool? = false
    var sampleTime: Double = 0
    private var next = 0

    lazy var session = CaptureSession(ring: { [unowned self] in self.ring },
                                      hostIsPlaying: { [unowned self] in self.playing })

    /// One render cycle of `frames`: the render block's capture lines, then the clock advances.
    func render(_ frames: Int) {
        if let ring, ring.capturing.load(ordering: .acquiring) {
            ring.noteStart(sampleTime: sampleTime)
            push(ring, from: next, frames: frames)
        }
        next += frames
        sampleTime += Double(frames)
    }
}

@MainActor @Test func recordCapturesUntilStopAndBuildsTheTake() throws {
    let host = FakeHost()
    host.render(512)  // before Record: not captured
    #expect(host.session.start())
    #expect(host.session.phase == .capturing(followsTransport: false))

    for _ in 0..<10 { host.render(480) }
    host.session.tick()
    #expect(host.session.capturedFrames == 4800)
    #expect(abs(host.session.elapsed - 0.1) < 1e-9)
    host.render(480)

    let take = try #require(host.session.stop())
    #expect(host.session.phase == .idle)
    #expect(take.frameCount == 5280)
    #expect(take.sampleRate == 48_000)
    #expect(take.startSampleTime == 512)
    #expect(take.droppedFrames == 0)
    #expect(take.source.channelCount == 2)
    // The first captured frame is the first one rendered after Record.
    #expect(take.source.base(ofChannel: 0)[0] == 512)
    #expect(take.source.base(ofChannel: 1)[5279] == -5791)
    // 16 kHz mono, a third of the frames, and the peaks over it.
    #expect(abs(take.source.mono16k.count - 1760) <= 2)
    #expect(take.source.peaks.sampleCount == take.source.mono16k.count)
    #expect(host.session.capturedTake === take.source)

    // Nothing rendered after the stop reaches the ring.
    host.render(480)
    #expect(host.ring?.pendingFrames == 0)

    host.session.clear()
    #expect(host.session.capturedTake == nil)
}

@MainActor @Test func stopWithNothingRenderedGivesNoTake() {
    let host = FakeHost()
    #expect(host.session.start())
    #expect(host.session.stop() == nil)
    #expect(host.session.phase == .idle)
    #expect(host.session.stop() == nil)
}

@MainActor @Test func recordNeedsAllocatedRenderResources() {
    let host = FakeHost()
    host.ring = nil
    #expect(!host.session.start())
    #expect(host.session.phase == .idle)
}

@MainActor @Test func armWaitsForThePlayingEdgeAndStopsOnTheStopEdge() throws {
    let host = FakeHost()
    host.session.arm()
    #expect(host.session.phase == .armed)

    host.render(256)
    host.session.tick()
    #expect(host.session.phase == .armed)

    host.playing = true
    host.session.tick()
    #expect(host.session.phase == .capturing(followsTransport: true))

    for _ in 0..<4 { host.render(256) }
    host.session.tick()
    #expect(host.session.phase == .capturing(followsTransport: true))

    host.playing = false
    host.session.tick()
    #expect(host.session.phase == .idle)

    let take = try #require(host.session.take)
    #expect(take.frameCount == 1024)
    #expect(take.startSampleTime == 256)
}

@MainActor @Test func armingWhileTheHostPlaysWaitsForItsNextStart() {
    let host = FakeHost()
    host.playing = true
    host.session.arm()
    host.session.tick()
    #expect(host.session.phase == .armed)

    host.playing = false
    host.session.tick()
    #expect(host.session.phase == .armed)

    host.playing = true
    host.session.tick()
    #expect(host.session.phase == .capturing(followsTransport: true))
}

@MainActor @Test func stopWhileArmedDisarms() {
    let host = FakeHost()
    host.session.arm()
    #expect(host.session.stop() == nil)
    #expect(host.session.phase == .idle)

    host.playing = true
    host.session.tick()
    #expect(host.session.phase == .idle)
}

@MainActor @Test func aRecordedTakeIgnoresTheTransport() {
    let host = FakeHost()
    host.playing = true
    #expect(host.session.start())
    host.render(128)
    host.playing = false
    host.session.tick()
    #expect(host.session.phase == .capturing(followsTransport: false))
}

@MainActor @Test func theCaptureEndsWhenTheRingIsFullOfTenMinutes() throws {
    let host = FakeHost()
    host.ring = CaptureRing(capacityFrames: 1000, channels: 2, sampleRate: 48_000)
    #expect(host.session.start())

    for _ in 0..<4 { host.render(250) }
    host.session.tick()

    #expect(host.session.phase == .idle)
    #expect(try #require(host.session.take).frameCount == 1000)
}

@MainActor @Test func aRingReallocatedForAnotherFormatEndsTheCaptureWithWhatItHad() throws {
    let host = FakeHost()
    #expect(host.session.start())
    host.render(300)
    host.session.tick()
    host.render(200)

    host.ring?.capturing.store(false, ordering: .releasing)
    host.ring = CaptureRing(capacityFrames: 44_100, channels: 2, sampleRate: 44_100)
    host.session.tick()

    #expect(host.session.phase == .idle)
    #expect(try #require(host.session.take).frameCount == 500)
}

@Test func aTakeWithNoFramesIsNil() {
    #expect(CapturedTake.make(channels: [], sampleRate: 48_000, startSampleTime: 0) == nil)
    #expect(CapturedTake.make(channels: [[], []], sampleRate: 48_000, startSampleTime: 0) == nil)
    #expect(CapturedTake.make(channels: [[1]], sampleRate: 0, startSampleTime: 0) == nil)
}

@MainActor @Test func aRestoredTakeEndsTheCaptureAndReplacesTheTake() throws {
    let host = FakeHost()
    var reported: [Int?] = []
    host.session.onTakeChanged = { reported.append($0?.frameCount) }
    let restored = try #require(CapturedTake.make(channels: [numbered(0..<4800), numbered(0..<4800, sign: -1)],
                                                  sampleRate: 48_000, startSampleTime: 96))

    #expect(host.session.start())
    host.render(480)
    host.session.restore(restored)

    #expect(host.session.phase == .idle)
    #expect(host.session.capturedFrames == 0)
    #expect(host.session.take?.frameCount == 4800)
    #expect(host.session.take?.startSampleTime == 96)
    #expect(try #require(host.ring).capturing.load(ordering: .acquiring) == false)
    // Nothing more is captured, and Stop has no take of its own to give.
    host.render(480)
    #expect(host.session.stop() == nil)
    #expect(host.session.take?.frameCount == 4800)

    host.session.restore(nil)
    #expect(host.session.capturedTake == nil)
    #expect(reported == [nil, 4800, nil])
}
