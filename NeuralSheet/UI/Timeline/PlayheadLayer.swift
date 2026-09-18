import AppKit
import QuartzCore

/// The playhead: a 1 px `textBright` line, with the 9 px equilateral marker on the waveform's copy
/// (`Playhead::paint`). Drawn once into its own layer and moved, never redrawn, as the transport
/// runs — that is what keeps the roll underneath untouched at 120 Hz.
///
/// The layer is `triangleSide` wide, the line down its middle at the whole authored pixel the
/// playhead rounds to; ``PlayheadView`` positions it so that column lands on `playheadX`.
final class PlayheadLayer: CALayer {
    static let triangleSide: CGFloat = 9
    static let triangleHeight: CGFloat = 0.866_025_403_78 * triangleSide

    var scale: CGFloat = 1
    var drawsTriangle = true

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsGravity = .topLeft
    }

    override init(layer: Any) {
        super.init(layer: layer)

        if let other = layer as? PlayheadLayer {
            scale = other.scale
            drawsTriangle = other.drawsTriangle
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The layer's width in real points: the triangle's, rounded up to a whole pixel on each side.
    var layerWidth: CGFloat { (PlayheadLayer.triangleSide + 2) * scale }

    /// Where, from the layer's left edge, the line's pixel column starts.
    var lineOffset: CGFloat { ((PlayheadLayer.triangleSide + 2) / 2 - 0.5) * scale }

    override func draw(in ctx: CGContext) {
        // Hosted by a flipped view, so the context is already y-down: the triangle hangs from 0.
        let x = lineOffset
        ctx.fill(CGRect(x: x, y: 0, width: scale, height: bounds.height), TimelinePalette.textBright)

        guard drawsTriangle else { return }

        let centre = x + 0.5 * scale
        let half = PlayheadLayer.triangleSide / 2 * scale

        ctx.beginPath()
        ctx.move(to: CGPoint(x: centre - half, y: 0))
        ctx.addLine(to: CGPoint(x: centre + half, y: 0))
        ctx.addLine(to: CGPoint(x: centre, y: PlayheadLayer.triangleHeight * scale))
        ctx.closePath()
        ctx.setFillColor(TimelinePalette.textBright)
        ctx.fillPath()
    }
}

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
