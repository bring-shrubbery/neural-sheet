import AppKit
import NeuralSheetCore

/// The wheel and the pinch, as the Mac timeline takes them (`TimelineContainerView+Interaction`),
/// and the two zooms.
extension PluginRollView {
    override func scrollWheel(with event: NSEvent) {
        handleWheel(WheelGesture(event), at: convert(event.locationInWindow, from: nil))
    }

    /// `mouseWheelMove`: ⌘-wheel zooms time about the left edge, ⌥-wheel over the roll or the
    /// keys zooms pitch about the pointer, a wheel over the roll pans both axes at once, and over
    /// the waveform or the ruler either part scrolls time.
    func handleWheel(_ wheel: WheelGesture, at point: CGPoint) {
        let overRoll = point.y >= geometry.rollY * geometry.scale

        if keyboard.frame.contains(point) {
            if wheel.isOptionDown {
                zoomPitch(byWheel: wheel.juceDeltaY, at: point)
            } else if wheel.pixelDeltaY != 0 {
                scrollPitch(byPixels: wheel.pixelDeltaY)
            }
            return
        }

        guard scrollView.frame.contains(point) else { return }

        if wheel.isCommandDown {
            setZoom(geometry.zoom + wheel.juceDeltaY, keepingSecondsAtX: 0)
            return
        }

        if overRoll, wheel.isOptionDown {
            zoomPitch(byWheel: wheel.juceDeltaY, at: point)
            return
        }

        if overRoll, wheel.pixelDeltaY != 0 {
            scrollPitch(byPixels: wheel.pixelDeltaY)
        }

        let dx = overRoll ? wheel.pixelDeltaX : (wheel.pixelDeltaX != 0 ? wheel.pixelDeltaX : wheel.pixelDeltaY)

        if dx != 0 {
            scroll(toX: clip.bounds.minX - dx)
        }
    }

    /// `mouseMagnify`: the pinch multiplies the time zoom by JUCE's `1 / (1 − magnification)`,
    /// anchored on the left edge; with ⌥ held it zooms pitch about the pointer.
    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.option) {
            setVerticalZoom(ZoomMath.verticalZoom(from: currentVerticalNorm, magnification: Double(event.magnification)),
                            anchoringAt: point)
            return
        }

        let inverse = 1 - event.magnification

        guard inverse > 0 else { return }

        setZoom(geometry.zoom / Double(inverse), keepingSecondsAtX: 0)
    }

    // MARK: - Time

    /// `_setZoomLevel`: clamps (never out past the take), applies, and keeps the time under `x`
    /// (viewport points) where it was.
    func setZoom(_ zoom: Double, keepingSecondsAtX anchorX: CGFloat?) {
        let viewport = Double(clip.bounds.width / geometry.scale)
        let clamped = ZoomMath.clampHorizontal(zoom, viewportWidth: viewport, duration: geometry.duration)
        let anchor = anchorX.map { geometry.seconds(forX: clip.bounds.minX + $0) }
        let changed = abs(clamped - geometry.zoom) > 1e-9

        geometry.zoom = clamped
        layoutBands()

        if let anchor, let anchorX {
            scroll(toX: geometry.x(forSeconds: anchor) - anchorX)
            layoutBands()
        }

        if changed {
            waveform.needsDisplay = true
            ruler.needsDisplay = true
            roll.needsDisplay = true
            placeOverlays()
            wakePlayhead()
        }
    }

    // MARK: - Pitch

    /// Pans the pitch axis by real points; repaints only when the column actually moved.
    func scrollPitch(byPixels pixels: CGFloat) {
        let before = geometry.keyAxisOffset

        geometry.scrollKeys(byPixels: Double(pixels / geometry.scale))

        if geometry.keyAxisOffset != before {
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }
    }

    /// The zoom on screen now, set or automatic: a gesture continues from what is drawn.
    private var currentVerticalNorm: Double {
        ZoomMath.norm(forRowHeight: Double(geometry.rowHeight))
    }

    private func zoomPitch(byWheel delta: Double, at point: CGPoint) {
        guard delta != 0 else { return }

        setVerticalZoom(ZoomMath.verticalZoom(from: currentVerticalNorm, wheelDelta: delta), anchoringAt: point)
    }

    /// A gesture's zoom about the pitch under `point`; it takes the zoom off automatic.
    private func setVerticalZoom(_ norm: Double, anchoringAt point: CGPoint) {
        let anchorY = (point.y - keyboard.frame.minY) / geometry.scale

        verticalNorm = norm

        guard geometry.setRowHeight(CGFloat(ZoomMath.rowHeight(norm: norm)), anchoringY: anchorY) else { return }

        keyboard.needsDisplay = true
        roll.needsDisplay = true
        updateNoteRange(mayShrink: !content.isStreaming)
    }

    /// `VisualizationPanel::_applyVerticalZoom`: the zoom a gesture set, or the one that fits the
    /// notes' octaves; then the range derived against it.
    func applyVerticalZoom() {
        guard geometry.keyboardHeight > 0 else { return }

        var norm = verticalNorm

        if norm < 0 {
            let pitches = content.notes.map(\.pitch)
            let range = PianoRollRange.displayRange(notes: pitches.min(), highest: pitches.max(), minSemitones: 0)

            norm = ZoomMath.normForFit(visibleHeight: Double(geometry.keyboardHeight), semitones: range.count)
        }

        if geometry.setRowHeight(CGFloat(ZoomMath.rowHeight(norm: norm))) {
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }

        updateNoteRange(mayShrink: !content.isStreaming)
    }

    /// `VisualizationPanel::_updateNoteRange`: whole octaves covering every note and filling the
    /// column; while a run streams the range may only widen.
    private func updateNoteRange(mayShrink: Bool) {
        let pitches = content.notes.map(\.pitch)
        let minSemitones = geometry.rowHeight > 0
            ? Int((geometry.keyboardHeight / geometry.rowHeight - 1e-6).rounded(.up))
            : 0

        var range = PianoRollRange.displayRange(notes: pitches.min(), highest: pitches.max(),
                                                minSemitones: max(0, minSemitones))

        if !mayShrink {
            range = PianoRollRange.union(range, geometry.pitchRange)
        }

        if keyboard.isDimmed != pitches.isEmpty {
            keyboard.isDimmed = pitches.isEmpty
            keyboard.needsDisplay = true
        }

        if range != geometry.pitchRange {
            geometry.pitchRange = range
            geometry.settleFirstKey()
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }
    }
}
