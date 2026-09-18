import AppKit
import NeuralSheetCore

/// The 22 px time ruler (`TimeRuler`): absolute seconds only, a 1 px tick per division and an
/// `m:ss` label 6 px to its right. Nothing is drawn unless the transport can play.
final class RulerView: NSView {
    let geometry: TimelineGeometry

    var canPlay = false {
        didSet {
            if canPlay != oldValue {
                needsDisplay = true
            }
        }
    }

    let playhead = PlayheadView(drawsTriangle: false)

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    func configure() {
        playhead.configure(scale: geometry.scale, height: bounds.height)
    }

    func setPlayhead(x: CGFloat?) {
        guard let x else {
            playhead.isHidden = true
            return
        }

        playhead.isHidden = false
        playhead.move(toX: x)
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dirtyRect = rect.intersection(bounds)
        let k = geometry.scale
        let height = bounds.height

        ctx.fill(dirtyRect, TimelinePalette.bgPanel)
        ctx.fill(CGRect(x: dirtyRect.minX, y: height - k, width: dirtyRect.width, height: k), TimelinePalette.divSoft)

        guard canPlay else { return }

        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let division = RulerTicks.division(pixelsPerSecond: pixelsPerSecond)
        let font = TimelineFonts.meta(k)
        let labelInset = 6 * k
        let labelWidth = 40 * k

        guard division > 0, pixelsPerSecond > 0 else { return }

        // Only the ticks whose tick or label can touch the exposed sliver: the label extends
        // `labelInset + labelWidth` to the right of its tick.
        let firstIndex = max(0, Int(((dirtyRect.minX - labelInset - labelWidth) / k / CGFloat(pixelsPerSecond)
            / CGFloat(division)).rounded(.down)))
        let width = bounds.width

        var index = firstIndex

        while true {
            let time = Double(index) * division
            let x = CGFloat((time * pixelsPerSecond).rounded()) * k

            if x >= width || x > dirtyRect.maxX {
                break
            }

            ctx.fill(CGRect(x: x, y: 0, width: k, height: height), TimelinePalette.divTick)

            TimelineText.draw(TimeFormat.ruler(time), font: font, colour: TimelinePalette.textFaint,
                              in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                              anchor: .centredLeft, context: ctx)

            index += 1
        }
    }
}

/// The 46 px column beside the waveform and the ruler (`TimelineGutter`): the amplitude scale,
/// each label centred on the exact y its amplitude maps to. The ruler's share is deliberately empty.
final class GutterView: NSView {
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let k = scale
        let waveformHeight = TimelineMetrics.waveformHeight * k

        ctx.fill(rect.intersection(bounds), TimelinePalette.bgGutter)
        ctx.fill(CGRect(x: bounds.width - k, y: 0, width: k, height: bounds.height), TimelinePalette.divStrong)
        ctx.fill(CGRect(x: 0, y: waveformHeight - k, width: bounds.width, height: k), TimelinePalette.divSoft)
        ctx.fill(CGRect(x: 0, y: bounds.height - k, width: bounds.width, height: k), TimelinePalette.divSoft)

        let font = TimelineFonts.scaleLabel(k)
        let labelHeight = 9 * k
        let labelWidth = bounds.width - 6 * k

        func labelRect(amplitude: CGFloat) -> CGRect {
            let y = (TimelineMetrics.waveformCentreY - amplitude * TimelineMetrics.waveformAmpHalfSpan) * k

            return CGRect(x: 0, y: y - labelHeight / 2, width: labelWidth, height: labelHeight)
        }

        TimelineText.draw("+1.0", font: font, colour: TimelinePalette.textScale, in: labelRect(amplitude: 1),
                          anchor: .centredRight, context: ctx)
        TimelineText.draw("\u{2212}1.0", font: font, colour: TimelinePalette.textScale, in: labelRect(amplitude: -1),
                          anchor: .centredRight, context: ctx)
        TimelineText.draw("0", font: font, colour: TimelinePalette.textFaint, in: labelRect(amplitude: 0),
                          anchor: .centredRight, context: ctx)
    }
}
