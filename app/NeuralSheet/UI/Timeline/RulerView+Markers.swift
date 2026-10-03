import AppKit
import NeuralSheetCore

/// What the ruler's card is opened for (tempo map design §4; markers and lyrics design §2): the
/// bar under the pointer for the tempo section, the time under it for Add Marker Here, and the
/// marker whose flag was right-clicked, if any.
struct RulerCardTarget: Equatable {
    var bar: Int
    var seconds: Double
    var markerID: UUID? = nil
}

/// The section markers on the ruler (markers and lyrics design §2): a flag along the lower half
/// of the ruler at each marker, in both timeline tabs, below the tempo flags' row so the two
/// never cover each other. A 1 px stem at the marker, the name to its right clipped at the next
/// flag. The flag's label is its hit area: a drag moves the marker (to the grid when snap is
/// on), a double-click marks the range from it to the next, a right-click opens the ruler's card
/// on it, and a plain click does nothing.
extension RulerView {
    typealias MarkerFlag = RulerPainter.MarkerFlag

    /// A press on a flag: the marker, where the press began and where the marker was.
    struct MarkerPress {
        var id: UUID
        var x: CGFloat
        var seconds: Double
        var isDragging = false
    }

    /// One flag per marker, left to right, each clipped at the next.
    func markerFlags() -> [MarkerFlag] {
        painter.markerFlags(bounds: bounds)
    }

    /// The flag under `point`, the later one where two touch (it is drawn on top).
    func markerFlag(at point: CGPoint) -> MarkerFlag? {
        markerFlags().last { $0.frame.contains(point) }
    }

    // MARK: - Mouse

    /// A press on a flag is the marker's: true when it took it. A double-click marks the section
    /// at once.
    func beginMarkerPress(_ event: NSEvent, at point: CGPoint) -> Bool {
        guard let flag = markerFlag(at: point) else { return false }

        if event.clickCount >= 2 {
            markerPress = nil
            onMarkRange?(flag.id)
        } else {
            markerPress = MarkerPress(id: flag.id, x: point.x, seconds: flag.seconds)
        }

        return true
    }

    /// The marker follows the pointer once the press has travelled past the drag threshold.
    func dragMarker(_ event: NSEvent) -> Bool {
        guard var press = markerPress else { return false }

        let x = convert(event.locationInWindow, from: nil).x

        if !press.isDragging, abs(x - press.x) < RulerView.dragThreshold * geometry.scale { return true }

        press.isDragging = true
        markerPress = press

        var seconds = press.seconds + Double((x - press.x) / max(geometry.pixelsPerSecond, 1e-9))

        if snapEnabled, let grid {
            seconds = grid.snap(seconds)
        }

        onMoveMarker?(press.id, min(max(seconds, 0), geometry.duration))

        return true
    }

    /// The press is over; a click that never dragged does nothing.
    func endMarkerPress() -> Bool {
        guard markerPress != nil else { return false }

        markerPress = nil

        return true
    }
}
