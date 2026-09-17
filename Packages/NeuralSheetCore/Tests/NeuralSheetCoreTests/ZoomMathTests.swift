import Testing

@testable import NeuralSheetCore

@Test func theHorizontalScaleIsAHundredPixelsPerSecond() {
    #expect(ZoomMath.basePixelsPerSecond == 100.0)
    #expect(ZoomMath.minZoom == 0.1)
    #expect(ZoomMath.maxZoom == 5.0)
}

@Test func zoomNeverGoesBelowFillingTheViewport() {
    // A 10 s take in a 1000 px viewport fills it at exactly 1.0, so nothing below that is allowed.
    #expect(ZoomMath.clampHorizontal(0.5, viewportWidth: 1000, duration: 10) == 1.0)
    #expect(ZoomMath.clampHorizontal(2, viewportWidth: 1000, duration: 10) == 2.0)

    // A take longer than the viewport can hold at 1.0 keeps the plain floor.
    #expect(ZoomMath.clampHorizontal(0.05, viewportWidth: 1000, duration: 100) == 0.1)

    // A take too short to fill the viewport at any zoom is pinned to the ceiling, not above it.
    #expect(ZoomMath.clampHorizontal(1, viewportWidth: 1000, duration: 1) == 5.0)
    #expect(ZoomMath.clampHorizontal(9, viewportWidth: 1000, duration: 1) == 5.0)
}

@Test func zoomClampsToTheFlatRangeWithoutAudio() {
    #expect(ZoomMath.clampHorizontal(0.05, viewportWidth: 1000, duration: 0) == 0.1)
    #expect(ZoomMath.clampHorizontal(9, viewportWidth: 1000, duration: 0) == 5.0)
    #expect(ZoomMath.clampHorizontal(0.05, viewportWidth: 0, duration: 10) == 0.1)
    #expect(ZoomMath.clampHorizontal(2, viewportWidth: 0, duration: 10) == 2.0)
}

@Test func contentIsNeverNarrowerThanTheViewport() {
    #expect(ZoomMath.contentWidth(zoom: 1, duration: 10, viewportWidth: 500) == 1000)
    #expect(ZoomMath.contentWidth(zoom: 0.1, duration: 1, viewportWidth: 500) == 500)
    #expect(ZoomMath.contentWidth(zoom: 1, duration: 0, viewportWidth: 500) == 500)
    // Rounded to a whole pixel, as the region's width is.
    #expect(ZoomMath.contentWidth(zoom: 1, duration: 12.345, viewportWidth: 100) == 1235)
}

@Test func rowHeightSpansSixToFortyThreePointSix() {
    #expect(ZoomMath.rowHeightMin == 6.0)
    #expect(ZoomMath.rowHeightRange == 37.6)
    #expect(ZoomMath.rowHeight(norm: 0) == 6)
    #expect(ZoomMath.rowHeight(norm: 1) == 43.6)
    #expect(abs(ZoomMath.rowHeight(norm: 0.5) - 24.8) < 1e-12)
    // Out of range positions are clamped rather than extrapolated.
    #expect(ZoomMath.rowHeight(norm: -1) == 6)
    #expect(ZoomMath.rowHeight(norm: 2) == 43.6)
}

@Test func normForFitInvertsRowHeight() {
    #expect(ZoomMath.normForFit(visibleHeight: 6 * 24, semitones: 24) == 0)
    #expect(abs(ZoomMath.normForFit(visibleHeight: 43.6 * 24, semitones: 24) - 1) < 1e-12)
    #expect(abs(ZoomMath.normForFit(visibleHeight: 24.8 * 36, semitones: 36) - 0.5) < 1e-12)

    // A range that cannot fit even zoomed all the way out falls back to 0.
    #expect(ZoomMath.normForFit(visibleHeight: 100, semitones: 64) == 0)
    // And one that would fit at more than full zoom stops at 1.
    #expect(ZoomMath.normForFit(visibleHeight: 4000, semitones: 12) == 1)

    // Never fewer than one octave on screen, which is what caps the zoom in.
    #expect(
        ZoomMath.normForFit(visibleHeight: 480, semitones: 3)
            == ZoomMath.normForFit(visibleHeight: 480, semitones: 12))
    #expect(ZoomMath.normForFit(visibleHeight: 480, semitones: 0) == ZoomMath.normForFit(visibleHeight: 480, semitones: 12))
}
