import AppKit
import NeuralSheetCore
import QuartzCore

/// The playhead and the decode frontier over the scroll view, and the display link that moves the
/// playhead: one ``PlayheadView`` (the Mac's layer, drawn once and moved) across the strip, the
/// ruler and the roll, and the frontier's shade and line while a run streams.
extension PluginRollView {
    // MARK: - Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Released on every way out of a window; made again in the next one.
        displayLink?.invalidate()
        displayLink = nil

        guard window != nil else { return }

        // Through a proxy: the link retains its target, and the roll must not outlive its window
        // because of it.
        let link = displayLink(target: displayLinkProxy, selector: #selector(PluginDisplayLinkProxy.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleTicks = 0
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        playhead.configure(scale: geometry.scale, height: bounds.height)
    }

    /// Wakes the link for anything that moves the playhead or the view: new content, a scroll, a
    /// zoom, a resize, a transport command or the host starting. It pauses itself again once the
    /// playhead stops moving.
    func wakePlayhead() {
        idleTicks = 0
        displayLink?.isPaused = false
        updatePlayhead()
    }

    /// One frame: the playhead from the transport. After a few frames without a move the link
    /// stops until something wakes it.
    func tick() {
        let before = playhead.frame.origin.x
        let wasHidden = playhead.isHidden

        updatePlayhead()

        if playhead.frame.origin.x != before || playhead.isHidden != wasHidden {
            idleTicks = 0
        } else {
            idleTicks += 1

            if idleTicks >= 4 {
                displayLink?.isPaused = true
            }
        }
    }

    /// Puts the playhead's pixel column on the transport's position, in the overlay's coordinates;
    /// hidden without a take or a position.
    func updatePlayhead() {
        guard content.duration > 0, geometry.duration > 0, let seconds = playheadSeconds() else {
            playhead.isHidden = true
            return
        }

        let x = geometry.playheadX(seconds: seconds) - clip.bounds.minX

        if playhead.frame.height != bounds.height {
            playhead.configure(scale: geometry.scale, height: bounds.height)
        }

        playhead.isHidden = false
        playhead.move(toX: x)
    }

    /// `PianoRoll::_drawTranscriptionFrontier`: everything right of the frontier shaded while a
    /// run goes, with a 1 px line on it, over the roll only.
    func placeOverlays() {
        let k = geometry.scale
        let top = geometry.rollY * k
        let height = max(0, bounds.height - top)
        let width = overlay.bounds.width

        guard let frontier = content.frontier else {
            frontierShade.isHidden = true
            frontierLine.isHidden = true
            return
        }

        let x = geometry.x(forSeconds: frontier) - clip.bounds.minX

        guard x < width else {
            frontierShade.isHidden = true
            frontierLine.isHidden = true
            return
        }

        let left = max(0, x)
        frontierShade.isHidden = false
        frontierShade.set(frame: CGRect(x: left, y: top, width: width - left, height: height))
        frontierLine.isHidden = x < 0
        frontierLine.set(frame: CGRect(x: (x / k).rounded() * k, y: top, width: k, height: height))
    }
}
