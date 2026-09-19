import Testing

@testable import NeuralSheetCore

@Test func litSegmentsSpanTheWholeScale() {
    #expect(MeterScale.litSegments(db: 0, count: 26) == 26)
    #expect(MeterScale.litSegments(db: -36, count: 26) == 0)
    #expect(MeterScale.litSegments(db: -18, count: 16) == 8)
}

@Test func litSegmentsClampOutsideTheScale() {
    #expect(MeterScale.litSegments(db: 6, count: 26) == 26)
    #expect(MeterScale.litSegments(db: -120, count: 16) == 0)
    #expect(MeterScale.litSegments(db: .infinity, count: 26) == 0)
    #expect(MeterScale.litSegments(db: .nan, count: 26) == 0)
    #expect(MeterScale.litSegments(db: -6, count: 0) == 0)
}

@Test func theScaleConstantsAreTheMetersOwn() {
    #expect(MeterScale.minDb == -36.0)
    #expect(MeterScale.maxDb == 0.0)
    #expect(MeterScale.midDb == -12.0)
    #expect(MeterScale.hotDb == -6.0)
}

@Test func bandBoundariesComeFromDecibelsNotFromTheIndex() {
    // N = 26: 0-16 low, 17-20 mid, 21-25 hot.
    #expect(MeterScale.band(segment: 16, count: 26) == .low)
    #expect(MeterScale.band(segment: 17, count: 26) == .mid)
    #expect(MeterScale.band(segment: 20, count: 26) == .mid)
    #expect(MeterScale.band(segment: 21, count: 26) == .hot)
    #expect(MeterScale.band(segment: 0, count: 26) == .low)
    #expect(MeterScale.band(segment: 25, count: 26) == .hot)

    // N = 16: 0-9 low, 10-12 mid, 13-15 hot.
    #expect(MeterScale.band(segment: 9, count: 16) == .low)
    #expect(MeterScale.band(segment: 10, count: 16) == .mid)
    #expect(MeterScale.band(segment: 12, count: 16) == .mid)
    #expect(MeterScale.band(segment: 13, count: 16) == .hot)
    #expect(MeterScale.band(segment: 15, count: 16) == .hot)
}

@Test func ballisticsReleaseAtTwentyFourDecibelsPerSecond() {
    var ballistics = MeterBallistics()

    // Instant attack puts it at the top of the scale on the frame the hit lands.
    #expect(ballistics.advance(input: 0, dt: 0) == 0)

    // One second of frames at the vblank clamp: a full second drains 24 dB.
    var db = 0.0
    for _ in 0..<10 {
        db = ballistics.advance(input: -36, dt: 0.1)
    }

    #expect(abs(db - (-24)) < 1e-9)
}

@Test func ballisticsStartAtTheFloorAndAttackInstantly() {
    var ballistics = MeterBallistics()

    #expect(ballistics.value == MeterScale.minDb)
    #expect(ballistics.advance(input: -10, dt: 0.1) == -10)
    // A level above the top of the scale is held at the top, not above it.
    #expect(ballistics.advance(input: 12, dt: 0.1) == 0)
}

@Test func ballisticsClampTheFrameInterval() {
    var ballistics = MeterBallistics()
    _ = ballistics.advance(input: 0, dt: 0)

    // A stalled frame must not drop the release by a whole range at once: dt clamps to 0.1 s.
    #expect(abs(ballistics.advance(input: -36, dt: 5) - (-2.4)) < 1e-9)
    // A negative interval cannot make the meter rise.
    #expect(abs(ballistics.advance(input: -36, dt: -1) - (-2.4)) < 1e-9)
}

@Test func ballisticsNeverReleasePastTheInput() {
    var ballistics = MeterBallistics()
    _ = ballistics.advance(input: 0, dt: 0)

    #expect(ballistics.advance(input: -1, dt: 0.1) == -1)
}
