/// The timeline's horizontal scale and the piano roll's vertical one.
public enum ZoomMath {
    /// The horizontal scale at a zoom of 1.0.
    public static let basePixelsPerSecond = 100.0
    public static let minZoom = 0.1
    public static let maxZoom = 5.0

    /// The lowest zoom the view allows: never below the floor, and never above the ceiling either —
    /// a take shorter than the viewport cannot fill it at any zoom, and an inverted range would
    /// make the clamp meaningless.
    public static func minHorizontalZoom(viewportWidth: Double, duration: Double) -> Double {
        guard duration > 0, viewportWidth > 0, duration.isFinite, viewportWidth.isFinite else {
            return minZoom
        }

        let fitsViewport = viewportWidth / (basePixelsPerSecond * duration)

        return min(max(fitsViewport, minZoom), maxZoom)
    }

    /// A zoom level brought into range, so you can never zoom out past the end of the take.
    public static func clampHorizontal(_ z: Double, viewportWidth: Double, duration: Double)
        -> Double
    {
        let lower = minHorizontalZoom(viewportWidth: viewportWidth, duration: duration)

        guard z.isFinite else { return lower }

        return min(max(z, lower), maxZoom)
    }

    /// The scrollable width of the timeline, in whole pixels, never less than the viewport.
    public static func contentWidth(zoom: Double, duration: Double, viewportWidth: Double) -> Double
    {
        let width = (zoom * basePixelsPerSecond * duration).rounded()

        guard width.isFinite else { return max(viewportWidth, 0) }

        return max(width, viewportWidth)
    }

    /// The per-semitone lane height at the zoom slider's two ends.
    public static let rowHeightMin = 6.0
    public static let rowHeightRange = 37.6

    /// Never fewer than one octave on screen, which is what caps the zoom in.
    public static let minVisibleSemitones = 12

    /// One semitone's lane height at a slider position. 0 is zoomed out.
    public static func rowHeight(norm: Double) -> Double {
        guard norm.isFinite else { return rowHeightMin }

        return rowHeightMin + min(max(norm, 0), 1) * rowHeightRange
    }

    /// The largest zoom that still shows `semitones` at once, so the view never crops content at
    /// rest. Falls back to 0 when the range cannot fit even zoomed all the way out.
    public static func normForFit(visibleHeight: Double, semitones: Int) -> Double {
        let span = max(minVisibleSemitones, semitones)
        let norm = (visibleHeight / Double(span) - rowHeightMin) / rowHeightRange

        guard norm.isFinite else { return 0 }

        return min(max(norm, 0), 1)
    }
}
