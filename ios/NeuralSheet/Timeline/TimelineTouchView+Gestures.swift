import NeuralSheetCore
import UIKit

/// Touch on the timeline (iOS app design §2): one finger pans both axes (the scroll view); a pinch
/// zooms time about its centre, or pitch when the fingers are spread vertically; a double tap
/// fits both again; a tap on a note selects and auditions it, on empty lanes seeks; a tap on the
/// ruler or the waveform seeks and a drag along the ruler marks a range; a tap on a key auditions
/// it. Long-press is left for the note card (sub-issue F).
extension TimelineTouchView: UIGestureRecognizerDelegate {
    /// A pinch in progress: which axis it took, and the zoom it started from.
    struct PinchState {
        enum Axis { case time, pitch }

        var axis: Axis?
        var startZoom: Double = 1
        var startRowHeight: CGFloat = 0
    }

    /// The minimum hit target (Human Interface Guidelines): a thinner note gets a zone this tall
    /// and wide, centred on it.
    static let minimumHitTarget: CGFloat = 44

    func installGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let rulerPan = UIPanGestureRecognizer(target: self, action: #selector(handleRulerPan(_:)))
        rulerPan.delegate = self
        rulerPan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(rulerPan)
        scrollView.panGestureRecognizer.require(toFail: rulerPan)

        let keyTap = UITapGestureRecognizer(target: self, action: #selector(handleKeyTap(_:)))
        keyboard.addGestureRecognizer(keyTap)
    }

    /// The ruler's drag only begins on the ruler; anywhere else the scroll view pans.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is UIPanGestureRecognizer, recognizer.view === scrollView else {
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        let start = recognizer.location(in: ruler)
        let travel = (recognizer as? UIPanGestureRecognizer)?.translation(in: ruler) ?? .zero

        return ruler.bounds.contains(CGPoint(x: start.x - travel.x, y: start.y - travel.y)) && model.canPlay
    }

    // MARK: - Taps

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if roll.bounds.contains(recognizer.location(in: roll)) {
            let point = recognizer.location(in: roll)

            if let hit = noteHit(at: point) {
                model.select(hit.id)
                model.audition(hit.note)
            } else {
                model.select(nil)
                seek(toX: point.x)
            }

            return
        }

        // The waveform, the ruler and the chord lane: a seek.
        seek(toX: recognizer.location(in: ruler).x)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        setZoom(ZoomMath.minZoom, keepingSecondsAtX: 0)
        model.setVerticalZoom(-1)
        applyVerticalZoom()
    }

    @objc private func handleKeyTap(_ recognizer: UITapGestureRecognizer) {
        guard let pitch = keyboard.pitch(at: recognizer.location(in: keyboard)) else { return }

        model.audition(pitch: pitch)
    }

    private func seek(toX x: CGFloat) {
        model.seek(toSeconds: geometry.seconds(forX: x))
        updatePlayhead()
        wakeDisplayLink()
    }

    /// The note a tap at `point` (roll coordinates) lands on: every note whose rect, grown to the
    /// minimum hit target where it is thinner, contains the point; the nearest rect wins, and
    /// among equals the one drawn last (on top). Placeholder notes of a streaming run hit nothing.
    func noteHit(at point: CGPoint) -> (id: NoteID, note: NoteEvent)? {
        guard !model.notesArePlaceholders else { return nil }

        let painter = roll.painter
        let half = TimelineTouchView.minimumHitTarget / 2
        let sliver = CGRect(x: point.x - half, y: 0, width: 2 * half, height: roll.bounds.height)
        var best: (index: Int, distance: CGFloat)?

        for index in painter.indices(crossing: sliver, of: painter.notes, buckets: painter.buckets) {
            guard let rect = painter.noteRect(painter.notes[index], height: roll.bounds.height) else { continue }

            let zone = rect.insetBy(dx: -max(0, (2 * half - rect.width) / 2), dy: -max(0, (2 * half - rect.height) / 2))

            guard zone.contains(point) else { continue }

            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()

            if best == nil || distance <= best!.distance {
                best = (index, distance)
            }
        }

        return best.map { (painter.ids[$0.index], painter.notes[$0.index]) }
    }

    // MARK: - Pinch

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard recognizer.numberOfTouches >= 2 else { return }

            let a = recognizer.location(ofTouch: 0, in: self)
            let b = recognizer.location(ofTouch: 1, in: self)

            pinch.axis = abs(a.y - b.y) > abs(a.x - b.x) ? .pitch : .time
            pinch.startZoom = geometry.zoom
            pinch.startRowHeight = geometry.rowHeight
            wakeDisplayLink()

        case .changed:
            switch pinch.axis {
            case .time?:
                let anchor = recognizer.location(in: scrollView).x - scrollView.contentOffset.x
                setZoom(pinch.startZoom * Double(recognizer.scale), keepingSecondsAtX: anchor)

            case .pitch?:
                let lowest = CGFloat(ZoomMath.rowHeightMin)
                let highest = CGFloat(ZoomMath.rowHeight(norm: 1))
                let rowHeight = min(max(pinch.startRowHeight * recognizer.scale, lowest), highest)
                let anchorY = recognizer.location(in: keyboard).y / geometry.scale

                if geometry.setRowHeight(rowHeight, anchoringY: anchorY) {
                    model.setVerticalZoom(ZoomMath.norm(forRowHeight: Double(rowHeight)))
                    updateNoteRange(mayShrink: model.run == nil)
                    layoutBands()
                    roll.setNeedsDisplay()
                    keyboard.setNeedsDisplay()
                }

            case nil:
                break
            }

        default:
            pinch.axis = nil
        }
    }

    // MARK: - Ruler

    /// A drag along the ruler marks the range, both ends on the grid when it snaps, as the Mac's
    /// ruler drag does (region design §6.2).
    @objc private func handleRulerPan(_ recognizer: UIPanGestureRecognizer) {
        let x = recognizer.location(in: ruler).x

        switch recognizer.state {
        case .began:
            rulerPressX = x - recognizer.translation(in: ruler).x
            fallthrough

        case .changed, .ended:
            guard let start = rulerPressX else { return }

            var lower = geometry.seconds(forX: min(start, x))
            var upper = geometry.seconds(forX: max(start, x))

            if model.editor.snapEnabled {
                lower = model.editor.grid.snap(lower)
                upper = model.editor.grid.snap(upper)
            }

            model.setRange(lower ..< max(lower, upper))

            if recognizer.state == .ended { rulerPressX = nil }

        default:
            rulerPressX = nil
        }
    }
}
