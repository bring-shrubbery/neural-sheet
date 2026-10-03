import AppKit
import QuartzCore

/// A view that hosts one ``PlayheadLayer`` and slides it along the time axis. Never hit-testable:
/// the click underneath is the seek.
final class PlayheadView: NSView {
    let playheadLayer = PlayheadLayer()

    init(drawsTriangle: Bool) {
        super.init(frame: .zero)
        playheadLayer.drawsTriangle = drawsTriangle
        layer = playheadLayer
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(scale: CGFloat, height: CGFloat) {
        playheadLayer.scale = scale
        playheadLayer.contentsScale = window?.backingScaleFactor ?? 2
        frame.size = CGSize(width: playheadLayer.layerWidth, height: height)
        playheadLayer.setNeedsDisplay()
    }

    /// Puts the line's pixel column at `x`, in the superview's coordinates.
    func move(toX x: CGFloat) {
        let origin = CGPoint(x: x - playheadLayer.lineOffset, y: 0)

        if frame.origin != origin {
            frame.origin = origin
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        playheadLayer.contentsScale = window?.backingScaleFactor ?? 2
        playheadLayer.setNeedsDisplay()
    }
}

/// A flat rectangle of one colour, for the washes and lines that move with the playhead or the
/// decode frontier: the played region's tint and its edge, the frontier's shade and its line.
/// `updateLayer` rather than `draw`, so there is no backing store however wide it gets.
final class FillView: NSView {
    private let colour: CGColor

    init(colour: CGColor) {
        self.colour = colour
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = colour
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(frame newFrame: CGRect) {
        if frame != newFrame {
            frame = newFrame
        }
    }
}
