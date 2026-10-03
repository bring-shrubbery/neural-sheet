import NeuralSheetCore
import QuartzCore
import UIKit

/// The playhead: the Mac's `PlayheadLayer` copies on the waveform (with its marker), the ruler,
/// the chord lane and the roll, and the played washes, moved by a `CADisplayLink` at the screen's
/// rate reading the engine's playhead -- never a redraw of the bands under them. While the take
/// plays the view follows it, unless a finger is on the timeline.
extension TimelineTouchView {
    /// The link through a proxy, so its retain of the target never keeps the view alive; it is
    /// invalidated whenever the view leaves its window.
    func startDisplayLink() {
        let proxy = DisplayLinkProxy()
        proxy.target = self

        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleTicks = 0
    }

    /// Wakes the link for anything that moves the playhead or the view outside the transport.
    func wakeDisplayLink() {
        idleTicks = 0
        displayLink?.isPaused = false
    }

    func tick() {
        guard hasSynced else { return }

        updatePlayhead()

        let playing = model.isPlaying

        // The take ran out under the transport: Play is Play again.
        if !playing, model.isTransportRunning {
            model.isTransportRunning = false
            model.playheadSeconds = model.engine.playheadSeconds
        }
        let touching = scrollView.isTracking || scrollView.isDecelerating || pinch.axis != nil

        if playing, model.followPlayhead, !touching {
            follow()
        }

        // Nothing moves on its own unless the transport runs: after a few quiet frames the link
        // stops until a sync, a seek or a scroll wakes it.
        if playing {
            idleTicks = 0
        } else {
            idleTicks += 1

            if idleTicks >= 4 {
                displayLink?.isPaused = true
            }
        }
    }

    /// Every copy of the playhead and the washes left of it, from the engine; hidden while there
    /// is no take to play.
    func updatePlayhead() {
        let x: CGFloat? = model.canPlay ? geometry.playheadX(seconds: model.engine.playheadSeconds) : nil
        let screenScale = window?.screen.scale ?? traitCollection.displayScale
        let k = geometry.scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        waveform.playhead.place(atX: x, height: waveform.bounds.height, scale: k, screenScale: screenScale)
        ruler.playhead.place(atX: x, height: ruler.bounds.height, scale: k, screenScale: screenScale)
        chordLane.playhead.place(atX: x, height: chordLane.bounds.height, scale: k, screenScale: screenScale)
        roll.playhead.place(atX: x, height: roll.bounds.height, scale: k, screenScale: screenScale)

        // `if (playhead_x > 0)`: nothing is washed at the start.
        if let x, x > 0 {
            waveform.wash.set(frame: CGRect(x: 0, y: 0, width: x, height: waveform.bounds.height))
            waveform.washEdge.set(frame: CGRect(x: x - k, y: 0, width: k, height: waveform.bounds.height))
            roll.wash.set(frame: CGRect(x: 0, y: 0, width: x, height: roll.bounds.height))
        } else {
            waveform.wash.set(frame: nil)
            waveform.washEdge.set(frame: nil)
            roll.wash.set(frame: nil)
        }

        CATransaction.commit()
    }

    /// The playhead held at the middle of the view; Reduce Motion turns a page at the edge
    /// instead (a11y design §2).
    private func follow() {
        let viewport = scrollView.bounds.width
        let maxX = max(0, scrollView.contentSize.width - viewport)
        let x = geometry.playheadX(seconds: model.engine.playheadSeconds)
        let current = scrollView.contentOffset.x
        let target: CGFloat

        if Accommodations.shared.reduceMotion {
            guard x < current || x > current + viewport else { return }

            target = x
        } else {
            target = x - viewport / 2
        }

        let clamped = min(max(0, target), maxX)

        if abs(clamped - current) >= 0.5 {
            scrollView.contentOffset.x = clamped
        }
    }
}

/// The display link's target: weak on the view, so the link's own retain never keeps it alive.
final class DisplayLinkProxy: NSObject {
    weak var target: TimelineTouchView?

    @objc func fire(_ link: CADisplayLink) {
        target?.tick()
    }
}
