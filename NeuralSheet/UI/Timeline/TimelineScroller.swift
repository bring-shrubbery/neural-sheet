import AppKit

/// The horizontal scroll view the waveform, ruler and roll live in: one horizontal scroller, legacy
/// style so it takes its 8 px strip below the roll as the JUCE viewport's did, and hidden when
/// the content fits.
final class TimelineScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        // The timeline is nowhere near a title bar; an automatic inset would push it down.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        horizontalScroller = TimelineScroller()
        contentView = TimelineClipView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Always legacy, whatever the system preference: the strip is part of the layout.
    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { _ = newValue }
    }

    override var isFlipped: Bool { true }

    /// The container handles every wheel and magnify gesture itself (`CombinedAudioMidiRegion`),
    /// so these reach it directly rather than being scrolled first.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }
}

/// A flipped clip view, so the document's y runs downward like every other timeline view.
final class TimelineClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// `LookAndFeel_V4::drawScrollbar` with the viewport's own colours: a `faderTrack` thumb, rounded
/// 4 and inset 1, brightened a quarter under the pointer, over a transparent track.
final class TimelineScroller: NSScroller {
    /// The UI scale, applied to the strip's thickness. A class property because AppKit asks the
    /// class for the width before any instance is laid out.
    nonisolated(unsafe) static var scale: CGFloat = 1

    private var isHovered = false

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        TimelineMetrics.scrollerThickness * scale
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }

        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent: the panel below shows through.
    }

    override func drawKnob() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let k = TimelineScroller.scale
        let knob = rect(for: .knob).insetBy(dx: 1 * k, dy: 1 * k)
        let colour = isHovered ? Theme.faderTrack.brighter(0.25) : Theme.faderTrack

        ctx.fillRoundedRect(knob, corner: 4 * k, TimelinePalette.cg(colour))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)

        if knobProportion < 1 {
            drawKnob()
        }
    }
}
