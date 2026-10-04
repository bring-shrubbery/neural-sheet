import AppKit

/// One wheel gesture, as the two units the timeline needs it in: pixel deltas for panning time
/// and pitch 1:1 (a mouse wheel's line deltas are turned into pixels at `pixelsPerLine`), and
/// JUCE's `MouseWheelDetails` scaling — precise deltas × 0.5 / 256, line deltas × 10 / 256
/// (`redirectMouseWheel`) — for the zoom steps. Shared with the Audio Unit's roll by path.
struct WheelGesture {
    var pixelDeltaX: CGFloat
    var pixelDeltaY: CGFloat
    var juceDeltaY: Double
    var isCommandDown: Bool
    var isOptionDown: Bool

    /// What one line of a notched wheel pans, in real points.
    static let pixelsPerLine: CGFloat = 16

    init(_ event: NSEvent) {
        isCommandDown = event.modifierFlags.contains(.command)
        isOptionDown = event.modifierFlags.contains(.option)

        if event.hasPreciseScrollingDeltas {
            pixelDeltaX = event.scrollingDeltaX
            pixelDeltaY = event.scrollingDeltaY
            juceDeltaY = Double(event.scrollingDeltaY) * 0.5 / 256
        } else {
            pixelDeltaX = event.scrollingDeltaX * WheelGesture.pixelsPerLine
            pixelDeltaY = event.scrollingDeltaY * WheelGesture.pixelsPerLine
            juceDeltaY = Double(event.deltaY) * 10 / 256
        }
    }

    init(pixelDeltaX: CGFloat, pixelDeltaY: CGFloat, isCommandDown: Bool, isOptionDown: Bool = false) {
        self.pixelDeltaX = pixelDeltaX
        self.pixelDeltaY = pixelDeltaY
        self.isCommandDown = isCommandDown
        self.isOptionDown = isOptionDown
        juceDeltaY = Double(pixelDeltaY) * 0.5 / 256
    }
}
