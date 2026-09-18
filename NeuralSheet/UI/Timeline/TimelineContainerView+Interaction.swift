import AppKit
import NeuralSheetCore

/// Zoom, scroll and the transport: `CombinedAudioMidiRegion`'s wheel, magnify and vblank rules.
extension TimelineContainerView {
    // MARK: - Horizontal zoom

    /// The viewport's width in authored pixels, which the zoom floor is derived from.
    private var viewportWidthAuthored: Double {
        Double(scrollView.contentView.bounds.width / scale)
    }

    /// The take's length for the zoom floor: nothing while recording, as `getAudioSampleDuration`
    /// answered 0 until the take was installed, so a short take does not zoom in under the user.
    private var clampDuration: Double {
        model.state == .recording ? 0 : geometry.duration
    }

    /// `CombinedAudioMidiRegion::refreshForAudioLength`: resizes, and pulls the zoom back inside
    /// what the current audio length allows.
    func refreshForAudioLength() {
        let allowed = ZoomMath.clampHorizontal(geometry.zoom, viewportWidth: viewportWidthAuthored,
                                               duration: clampDuration)

        if abs(allowed - geometry.zoom) < 1e-9 {
            layoutDocument()
            return
        }

        setZoom(allowed)
    }

    /// `_setZoomLevel`: clamps, applies, and writes the effective value back to the model.
    func setZoom(_ zoom: Double) {
        let clamped = ZoomMath.clampHorizontal(zoom, viewportWidth: viewportWidthAuthored, duration: clampDuration)

        geometry.zoom = clamped

        if abs(model.zoomLevel - clamped) > 1e-9 {
            model.zoomLevel = clamped
        }

        // The mirror sees the write before the observation does; keep the two in step.
        snapshot.zoomLevel = clamped

        layoutDocument()
        waveform.needsDisplay = true
        ruler.needsDisplay = true
        roll.needsDisplay = true
        roll.setFrontier(seconds: frontierSeconds)
        updatePlayhead()
    }

    /// A zoom that keeps the time at the left edge of the view where it is.
    func setZoomAnchored(_ zoom: Double) {
        let timeStart = geometry.seconds(forX: scrollView.contentView.bounds.minX)

        setZoom(zoom)
        scroll(toX: CGFloat((timeStart * ZoomMath.basePixelsPerSecond * geometry.zoom).rounded()) * scale)
    }

    // MARK: - Scrolling

    /// Scrolls the viewport so its left edge sits at `x` (real points), clamped to the content.
    func scroll(toX x: CGFloat) {
        let clip = scrollView.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let target = min(max(x, 0), maxX)

        guard abs(clip.bounds.minX - target) > 0.001 else { return }

        clip.scroll(to: CGPoint(x: target, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    /// `mouseWheelMove`: ⌘-wheel zooms about the left edge, a vertical wheel over the roll scrolls
    /// pitch, and everything else scrolls time — unless the view is following the playhead, where
    /// a scroll would be undone on the next frame.
    override func scrollWheel(with event: NSEvent) {
        handleWheel(WheelGesture(event), at: convert(event.locationInWindow, from: nil))
    }

    func handleWheel(_ wheel: WheelGesture, at point: CGPoint) {
        guard scrollView.frame.contains(point) else { return }

        if wheel.isCommandDown {
            setZoomAnchored(geometry.zoom + wheel.juceDeltaY)
            return
        }

        let overRoll = point.y >= scrollView.frame.minY + TimelineMetrics.pianoRollY * scale

        if overRoll, wheel.juceDeltaY != 0 {
            scrollPitch(byWheel: wheel.juceDeltaY)
            return
        }

        if model.followPlayhead, model.state.canPlay, model.isPlaying {
            return
        }

        // Only the time axis scrolls here, so a vertical wheel over the waveform or the ruler moves
        // through time too, as the JUCE viewport had it.
        let dx = wheel.pixelDeltaX != 0 ? wheel.pixelDeltaX : wheel.pixelDeltaY

        scroll(toX: scrollView.contentView.bounds.minX - dx)
    }

    /// `mouseMagnify`: the pinch multiplies the zoom, anchored on the left edge.
    override func magnify(with event: NSEvent) {
        handleMagnify(event.magnification)
    }

    /// The factor JUCE handed the C++ (`redirectMagnify` in `juce_NSViewComponentPeer_mac.mm`):
    /// `1 / (1 − magnification)`, so the gesture feels exactly as it did there.
    func handleMagnify(_ magnification: CGFloat) {
        let inverse = 1 - magnification

        guard inverse > 0 else { return }

        setZoomAnchored(geometry.zoom / Double(inverse))
    }

    /// A wheel over the key column itself (`KeyboardComponentBase::mouseWheelMove`).
    func scrollPitch(with wheel: WheelGesture) {
        if wheel.juceDeltaY != 0 {
            scrollPitch(byWheel: wheel.juceDeltaY)
        }
    }

    private func scrollPitch(byWheel delta: Double) {
        let before = Int(geometry.firstKey)

        geometry.scrollKeys(byWheel: delta)

        if Int(geometry.firstKey) != before {
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }
    }

    // MARK: - Display link

    /// One frame: the playhead layers, the follow-playhead centring, and the growing take while
    /// recording. Nothing here redraws the bands.
    func tick() {
        guard hasSynced else { return }

        let recording = model.state == .recording

        if recording {
            growRecording()
        }

        updatePlayhead()

        if model.followPlayhead, model.state.canPlay, model.isPlaying {
            centreViewOnPlayhead()
        }

        // Nothing moves on its own unless the transport runs or a take grows: after a few quiet
        // frames the link stops until a sync, a seek or a resize wakes it. A few rather than one,
        // so the model's own tick — which mirrors the engine after this one may have run — still
        // gets seen.
        if model.isPlaying || recording {
            idleTicks = 0
        } else {
            idleTicks += 1

            if idleTicks >= 4 {
                displayLink?.isPaused = true
            }
        }
    }

    /// Positions the three playhead copies and the washes from the transport's mirror. The roll's
    /// copy stays hidden until there is a transcription to follow, so it does not sweep across the
    /// Transcribe button (`PianoRoll::updateEnablements`).
    func updatePlayhead() {
        let state = model.state
        let showing = state.canPlay && geometry.duration > 0
        let x: CGFloat? = showing ? geometry.playheadX(seconds: model.playheadSeconds) : nil

        waveform.setPlayhead(x: x)
        ruler.setPlayhead(x: x)
        roll.setPlayhead(x: state.hasTranscription ? x : nil)
    }

    /// `_centerViewOnPlayhead`: the viewport positioned so the playhead sits at its centre.
    private func centreViewOnPlayhead() {
        let k = scale
        let playhead = Double(geometry.playheadX(seconds: model.playheadSeconds) / k)
        let fullWidth = Double(document.frame.width / k)
        let visibleWidth = Int(scrollView.contentView.bounds.width / k)
        let halfVisible = Double(visibleWidth / 2)
        let offset = max(0, min(playhead, fullWidth) - halfVisible).rounded()

        scroll(toX: CGFloat(offset) * k)
    }

    /// While recording the take grows every tick: the content widens with it, the view stays on
    /// the far right and the waveform repaints (`changeListenerCallback` while `Recording`).
    private func growRecording() {
        let duration = model.duration

        guard duration != geometry.duration else { return }

        geometry.duration = duration
        snapshot.duration = duration
        layoutDocument()
        scroll(toX: max(0, document.frame.width - scrollView.contentView.bounds.width))
        waveform.setNeedsDisplay(waveform.visibleRect)
    }
}

/// One wheel gesture, as the two units the timeline needs it in: the raw pixel deltas for
/// scrolling time 1:1, and JUCE's `MouseWheelDetails` scaling — precise deltas × 0.5 / 256, line
/// deltas × 10 / 256 (`redirectMouseWheel`) — for the zoom step and the pitch scroll.
struct WheelGesture {
    var pixelDeltaX: CGFloat
    var pixelDeltaY: CGFloat
    var juceDeltaY: Double
    var isCommandDown: Bool

    init(_ event: NSEvent) {
        pixelDeltaX = event.scrollingDeltaX
        pixelDeltaY = event.scrollingDeltaY
        isCommandDown = event.modifierFlags.contains(.command)

        if event.hasPreciseScrollingDeltas {
            juceDeltaY = Double(event.scrollingDeltaY) * 0.5 / 256
        } else {
            juceDeltaY = Double(event.deltaY) * 10 / 256
        }
    }

    init(pixelDeltaX: CGFloat, pixelDeltaY: CGFloat, isCommandDown: Bool) {
        self.pixelDeltaX = pixelDeltaX
        self.pixelDeltaY = pixelDeltaY
        self.isCommandDown = isCommandDown
        juceDeltaY = Double(pixelDeltaY) * 0.5 / 256
    }
}
