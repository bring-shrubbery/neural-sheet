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
    struct MarkerFlag: Equatable {
        var id: UUID
        var seconds: Double
        /// The label's box along the bottom of the ruler, its left edge on the marker.
        var frame: CGRect
        var name: String
    }

    /// A press on a flag: the marker, where the press began and where the marker was.
    struct MarkerPress {
        var id: UUID
        var x: CGFloat
        var seconds: Double
        var isDragging = false
    }

    /// One flag per marker, left to right, each clipped at the next.
    func markerFlags() -> [MarkerFlag] {
        guard canPlay, !markers.isEmpty else { return [] }

        let k = geometry.scale
        let font = TimelineFonts.meta(k)
        let height = RulerView.flagHeight * k
        let y = bounds.height - height - k
        let xs = markers.map { geometry.x(forSeconds: $0.seconds).rounded() }

        return markers.enumerated().map { index, marker in
            let x = xs[index]
            let natural = (marker.name.isEmpty ? 0 : TimelineText.width(marker.name, font: font)) + 2 * RulerView.flagPadX * k
            let room = index + 1 < xs.count ? max(k, xs[index + 1] - x) : natural

            return MarkerFlag(id: marker.id, seconds: marker.seconds,
                              frame: CGRect(x: x, y: y, width: min(natural, room), height: height), name: marker.name)
        }
    }

    /// The flag under `point`, the later one where two touch (it is drawn on top).
    func markerFlag(at point: CGPoint) -> MarkerFlag? {
        markerFlags().last { $0.frame.contains(point) }
    }

    /// Each flag touching the exposed sliver: the stem the ruler's full height, the label box,
    /// the name inside it, clipped to the box.
    func drawMarkerFlags(_ ctx: CGContext, in dirtyRect: CGRect) {
        let k = geometry.scale
        let font = TimelineFonts.meta(k)

        for flag in markerFlags() where flag.frame.maxX >= dirtyRect.minX && flag.frame.minX <= dirtyRect.maxX {
            ctx.fill(flag.frame, TimelinePalette.markerFlag)
            ctx.fill(CGRect(x: flag.frame.minX, y: 0, width: k, height: bounds.height), TimelinePalette.markerStem)

            guard !flag.name.isEmpty else { continue }

            ctx.saveGState()
            ctx.clip(to: flag.frame)
            TimelineText.draw(flag.name, font: font, colour: TimelinePalette.markerLabel,
                              in: flag.frame.insetBy(dx: RulerView.flagPadX * k, dy: 0), anchor: .centredLeft, context: ctx)
            ctx.restoreGState()
        }
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
