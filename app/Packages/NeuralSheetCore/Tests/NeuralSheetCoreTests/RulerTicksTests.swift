import Testing

@testable import NeuralSheetCore

@Test func divisionsAreTheRoundNumbersOfSeconds() {
    #expect(RulerTicks.divisions == [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60])
    #expect(RulerTicks.minLabelGap == 56.0)
}

@Test func theFirstDivisionWideEnoughToLabelIsChosen() {
    #expect(RulerTicks.division(pixelsPerSecond: 100) == 1)
    #expect(RulerTicks.division(pixelsPerSecond: 500) == 0.25)
    #expect(RulerTicks.division(pixelsPerSecond: 20) == 5)
}

@Test func theGapIsMetExactlyAtTheBoundary() {
    // 0.25 * 224 == 56, the first spacing that reaches the gap.
    #expect(RulerTicks.division(pixelsPerSecond: 224) == 0.25)
    #expect(RulerTicks.division(pixelsPerSecond: 223) == 0.5)
    // 1 * 56 == 56.
    #expect(RulerTicks.division(pixelsPerSecond: 56) == 1)
    #expect(RulerTicks.division(pixelsPerSecond: 55) == 2)
}

@Test func theEndsOfTheScaleFallBackToTheOutermostDivisions() {
    #expect(RulerTicks.division(pixelsPerSecond: 2000) == 0.1)
    // Zoomed so far out that even a minute is too narrow to label: the widest is still the best.
    #expect(RulerTicks.division(pixelsPerSecond: 0.5) == 60)
    #expect(RulerTicks.division(pixelsPerSecond: 0) == 60)
}
