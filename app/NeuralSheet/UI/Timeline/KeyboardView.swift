import AppKit
import NeuralSheetCore

/// The key column left of the piano roll (`Keyboard`, a `KeyboardComponentBase` facing right):
/// white keys with a 1 px gap on their bottom and right edges, black keys with a 1 px bottom gap,
/// every C labelled, and the whole column blended 40 % toward the gutter while there are no notes.
final class KeyboardView: NSView, KeyboardFocusableView, OwnsArrowKeys {
    let geometry: TimelineGeometry

    /// `Keyboard::setDimmed`: the column falls back while the roll beside it is empty.
    var isDimmed = false {
        didSet {
            if isDimmed != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The project's key; under Differentiate Without Colour its scale is marked on the keys,
    /// since the roll's lanes show it by shade alone (a11y design §2). Whole-view repaint: the
    /// caller decides.
    var key: MusicalKey?

    /// A wheel gesture over the keys scrolls pitch; the container applies it to the geometry and
    /// repaints the roll with it.
    var onWheel: ((NSEvent) -> Void)?

    /// VoiceOver's increment and decrement: the keys scrolled by so many semitones, up for a
    /// positive count; the container's, like the wheel.
    var onAccessibilityScroll: ((Int) -> Void)?

    /// The key under the pointer, which VoiceOver reads as the column's value.
    private var hoveredPitch: Int?
    private var trackingArea: NSTrackingArea?

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        KeyboardPainter.draw(ctx, in: rect.intersection(bounds), bounds: bounds, geometry: geometry, isDimmed: isDimmed, key: key)
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }

    // MARK: - Accessibility

    /// Follows the pointer for the key under it, VoiceOver's value. Mouse-moved only while the
    /// window is key, and nothing is drawn for it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredPitch = geometry.pitch(forY: convert(event.locationInWindow, from: nil).y)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredPitch = nil
        super.mouseExited(with: event)
    }

    /// An adjustable element (a11y design §2): its value the key under the pointer, or the keys
    /// on show without one; increment and decrement scroll the column an octave.
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }

    override func accessibilityLabel() -> String? {
        String(localized: "Keyboard", comment: "VoiceOver: the piano keys left of the piano roll")
    }

    override func accessibilityValue() -> Any? {
        if let hoveredPitch {
            return TimeFormat.pitchName(hoveredPitch)
        }

        let range = geometry.pitchRange
        let shown = range.low <= range.high
            ? (range.low...range.high).filter { geometry.keyRect($0).intersects(bounds) }
            : []

        guard let low = shown.first, let high = shown.last else { return nil }

        return String(localized: "\(TimeFormat.pitchName(low)) to \(TimeFormat.pitchName(high))",
                      comment: "VoiceOver: the keys on show, lowest to highest, e.g. \"C2 to C6\"")
    }

    override func accessibilityPerformIncrement() -> Bool {
        onAccessibilityScroll?(12)
        return onAccessibilityScroll != nil
    }

    override func accessibilityPerformDecrement() -> Bool {
        onAccessibilityScroll?(-12)
        return onAccessibilityScroll != nil
    }

    // MARK: - Keyboard focus

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }

    override func drawFocusRingMask() {
        NSBezierPath(rect: focusRingRect).fill()
    }

    override var focusRingMaskBounds: NSRect { focusRingRect }

    /// Focused, ↑ and ↓ scroll the keys an octave, as VoiceOver's increment and decrement do.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: _ = accessibilityPerformIncrement()
        case .downArrow?: _ = accessibilityPerformDecrement()
        default: super.keyDown(with: event)
        }
    }
}
