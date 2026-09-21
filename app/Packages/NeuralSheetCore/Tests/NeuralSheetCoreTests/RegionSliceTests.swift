import Testing

@testable import NeuralSheetCore

@Test func regionSliceWidensByTheContextAndClampsToTheTake() {
    let inside = RegionSlice(range: 10 ..< 15, duration: 60)
    #expect(inside?.start == 8)
    #expect(inside?.end == 17)
    #expect(inside?.sampleRange(sampleCount: 60 * 16_000) == 128_000 ..< 272_000)

    let atStart = RegionSlice(range: 0.5 ..< 3, duration: 60)
    #expect(atStart?.start == 0)
    #expect(atStart?.end == 5)

    let atEnd = RegionSlice(range: 58 ..< 60, duration: 60)
    #expect(atEnd?.start == 56)
    #expect(atEnd?.end == 60)
    // A take whose sample count falls short of its duration is not overrun.
    #expect(atEnd?.sampleRange(sampleCount: 959_000) == 896_000 ..< 959_000)
}

@Test func regionSliceRefusesASliverAndARangeOffTheTake() {
    #expect(RegionSlice(range: 10 ..< 10.05, duration: 60) == nil)
    #expect(RegionSlice(range: 61 ..< 62, duration: 60) == nil)
    #expect(RegionSlice(range: 1 ..< 2, duration: 0) == nil)
    #expect(RegionSlice(range: 59.95 ..< 61, duration: 60) != nil, "a range running off the end is clamped, not refused")
}
