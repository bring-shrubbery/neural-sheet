import AppKit
import NeuralSheetCore

/// What the pointer landed on.
struct RollHit: Equatable {
    var id: NoteID
    var zone: NoteHitZone
    var note: NoteEvent
}

/// The accent-outlined rubber band. Positioned, never repainted.
final class MarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TimelinePalette.marqueeFill
        layer?.borderColor = TimelinePalette.marqueeBorder
        layer?.borderWidth = scale
    }

    var scale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The roll's side of editing: hit testing, the selection outline and the drag preview.
extension PianoRollView {
    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        guard let interaction else { return }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let interaction else {
            super.cursorUpdate(with: event)
            return
        }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// The tool changed under a still pointer: the cursor follows without a mouse move.
    func refreshCursor() {
        guard let interaction, let window else { return }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)

        if visibleRect.contains(point) {
            interaction.cursor(at: point).set()
        }
    }

    // MARK: - Geometry

    /// The rect a note is drawn in, or nil when its pitch is off the range.
    func noteRect(_ note: NoteEvent) -> CGRect? {
        painter.noteRect(note, height: bounds.height)
    }

    /// The topmost note under `point` and where on it.
    func hit(at point: CGPoint) -> RollHit? {
        guard !buckets.isEmpty else { return nil }

        let k = geometry.scale
        let second = Int(max(0, geometry.seconds(forX: point.x)))

        guard second < buckets.count else { return nil }

        // Last drawn is topmost: walk the bucket backwards.
        for index in buckets[second].reversed() {
            let note = notes[index]

            guard let rect = noteRect(note),
                  let zone = EditGestureMath.hitZone(in: rect, at: point, edgeWidth: RollEditController.edgeWidth * k,
                                                     minimumWidthForEdges: RollEditController.minimumWidthForEdges * k)
            else { continue }

            return RollHit(id: ids[index], zone: zone, note: note)
        }

        return nil
    }

    /// Every note whose rect touches `rect`, for the marquee.
    func noteRects(intersecting rect: CGRect) -> [(id: NoteID, rect: CGRect)] {
        let area = rect.standardized

        guard !buckets.isEmpty else { return [] }

        let first = max(0, Int(geometry.seconds(forX: area.minX)))
        let last = min(buckets.count - 1, Int(geometry.seconds(forX: area.maxX)))

        guard first <= last else { return [] }

        var seen = Set<Int>()
        var result: [(id: NoteID, rect: CGRect)] = []

        for bucket in first...last {
            for index in buckets[bucket] where seen.insert(index).inserted {
                if let noteRect = noteRect(notes[index]), noteRect.intersects(area) {
                    result.append((ids[index], noteRect))
                }
            }
        }

        return result
    }

    // MARK: - Range

    /// The marked range and, while a region run is in flight, its progress (region design §6.3).
    func setRange(_ range: Range<Double>?, progress: Float?) {
        rangeBand.progress = progress
        RangeBandView.place(rangeBand, range: range, in: self, geometry: geometry)
    }
}
