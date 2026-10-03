import NeuralSheetCore
import QuartzCore
import UIKit

/// One band of the touch timeline: a `UIView` whose `draw(_:)` is the Mac band's shared painter
/// over the same ``TimelineGeometry`` (iOS app design §2). Like the Mac's bands it is a window a
/// few viewports wide that slides with the scroll, its bounds origin at the document x it sits
/// at, so it draws, hit-tests and places its layers in document coordinates.
class TimelineBandView: UIView {
    let geometry: TimelineGeometry

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The current CoreGraphics context and the exposed part of the band.
    func context(for rect: CGRect) -> (CGContext, CGRect)? {
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        return (ctx, rect.intersection(bounds))
    }
}

/// The piano roll: ``RollPainter`` (`PianoRollView+Drawing.swift`).
final class RollBandView: TimelineBandView {
    var painter: RollPainter

    let playhead = PlayheadLayer()
    let wash = TimelineFillLayer(colour: TimelinePalette.accentWashRoll)
    let frontierShade = TimelineFillLayer(colour: TimelinePalette.frontierShade)
    let frontierLine = TimelineFillLayer(colour: TimelinePalette.divStrong)
    let rangeBand = RangeBandLayer()

    override init(geometry: TimelineGeometry) {
        painter = RollPainter(geometry: geometry)
        super.init(geometry: geometry)
        accessibilityLabel = String(localized: "Piano roll", comment: "VoiceOver: the piano roll, which holds the notes")

        // The order the Mac stacks them in, over the lanes and the notes.
        for overlay in [wash, frontierShade, frontierLine, rangeBand] as [CALayer] {
            layer.addSublayer(overlay)
        }

        playhead.drawsTriangle = false
        layer.addSublayer(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let (ctx, dirty) = context(for: rect) else { return }

        painter.draw(ctx, in: dirty, bounds: bounds)

        if showsHandles {
            drawHandles(ctx, in: dirty)
        }
    }

    // MARK: - End handles

    /// Whether the selected notes show the end handles a drag resizes them by: while the roll
    /// can be edited.
    var showsHandles = false

    /// A handle's touch target: at least 22 pt wide, half the minimum hit target, straddling the
    /// note's end (iOS app design §2, Touch).
    static let handleWidth: CGFloat = 22
    /// More selected notes than this show no handles: a passage selected for a bulk command is not
    /// being resized note by note, and a forest of grips would hide the notes.
    static let handleLimit = 64

    /// The two touch targets of a note drawn at `rect`: `handleWidth` wide, reaching at most a
    /// third of the way into the note so a short one keeps a body to drag, and at least the
    /// minimum hit target tall.
    static func handleRects(for rect: CGRect) -> (start: CGRect, end: CGRect) {
        let inner = min(handleWidth / 2, rect.width / 3)
        let height = max(rect.height, TimelineTouchView.minimumHitTarget)
        let y = rect.midY - height / 2

        return (CGRect(x: rect.minX - (handleWidth - inner), y: y, width: handleWidth, height: height),
                CGRect(x: rect.maxX - inner, y: y, width: handleWidth, height: height))
    }

    /// A grip at each end of every selected note, where a drag previews it: a bar in the selection
    /// outline's colour, edged in the roll's ground so it reads over any instrument's fill.
    private func drawHandles(_ ctx: CGContext, in dirty: CGRect) {
        guard !painter.selection.isEmpty, painter.selection.count <= RollBandView.handleLimit else { return }

        let reach = RollBandView.handleWidth
        let sliver = dirty.insetBy(dx: -reach, dy: 0)
        let gripWidth: CGFloat = 4

        for index in painter.indices(crossing: sliver, of: painter.notes, buckets: painter.buckets)
        where painter.selection.contains(painter.ids[index]) {
            guard let shown = painter.previewed(painter.notes[index], id: painter.ids[index]),
                let rect = painter.noteRect(shown, height: bounds.height)
            else { continue }

            let height = max(rect.height + 6, 14)
            let inset = min(3, rect.width / 4)

            for x in [rect.minX + inset, rect.maxX - inset] {
                let grip = CGRect(x: x - gripWidth / 2, y: rect.midY - height / 2, width: gripWidth, height: height)
                let path = CGPath(roundedRect: grip, cornerWidth: gripWidth / 2, cornerHeight: gripWidth / 2, transform: nil)

                ctx.addPath(path)
                ctx.setFillColor(TimelinePalette.textPrimary)
                ctx.setStrokeColor(TimelinePalette.bgRoot)
                ctx.setLineWidth(1)
                ctx.drawPath(using: .fillStroke)
            }
        }
    }
}

/// The ruler: ``RulerPainter`` (`RulerView+Drawing.swift`).
final class RulerBandView: TimelineBandView {
    var painter: RulerPainter
    let playhead = PlayheadLayer()

    override init(geometry: TimelineGeometry) {
        painter = RulerPainter(geometry: geometry)
        super.init(geometry: geometry)
        playhead.drawsTriangle = false
        layer.addSublayer(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let (ctx, dirty) = context(for: rect) else { return }

        painter.draw(ctx, in: dirty, bounds: bounds)
    }
}

/// The 40 pt waveform strip of the Edit tab: ``WaveformPainter`` (`WaveformView+Drawing.swift`).
final class WaveformBandView: TimelineBandView {
    var peaks: WaveformPeaks?

    let playhead = PlayheadLayer()
    let wash = TimelineFillLayer(colour: TimelinePalette.accentWashWave)
    let washEdge = TimelineFillLayer(colour: TimelinePalette.accentWashEdge)
    let rangeBand = RangeBandLayer()

    override init(geometry: TimelineGeometry) {
        super.init(geometry: geometry)

        for overlay in [wash, washEdge, rangeBand] as [CALayer] {
            layer.addSublayer(overlay)
        }

        playhead.drawsTriangle = true
        layer.addSublayer(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let (ctx, dirty) = context(for: rect) else { return }

        WaveformPainter.draw(ctx, in: dirty, bounds: bounds, geometry: geometry, peaks: peaks, isCompact: true, isFileOver: false)
    }
}

/// The chord lane, while there are chords: ``ChordLanePainter`` (`ChordLaneView+Drawing.swift`).
final class ChordLaneBandView: TimelineBandView {
    var chords: [ChordEvent] = []
    var labels: [String] = []
    let playhead = PlayheadLayer()

    override init(geometry: TimelineGeometry) {
        super.init(geometry: geometry)
        playhead.drawsTriangle = false
        layer.addSublayer(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let (ctx, dirty) = context(for: rect) else { return }

        ChordLanePainter(geometry: geometry, chords: chords, labels: labels).draw(ctx, in: dirty, bounds: bounds)
    }
}

/// The key column left of the roll, fixed while the roll scrolls: ``KeyboardPainter``.
final class KeyboardBandView: TimelineBandView {
    var isDimmed = false
    var key: MusicalKey?

    override init(geometry: TimelineGeometry) {
        super.init(geometry: geometry)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Keyboard", comment: "VoiceOver: the piano keys left of the piano roll")
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let (ctx, dirty) = context(for: rect) else { return }

        KeyboardPainter.draw(ctx, in: dirty, bounds: bounds, geometry: geometry, isDimmed: isDimmed, key: key)
    }

    /// The key under `point`: a black key wins where it covers a white one, as on a piano.
    func pitch(at point: CGPoint) -> Int? {
        let range = geometry.pitchRange

        guard range.low <= range.high else { return nil }

        let notes = Array(range.low...range.high)

        return notes.first { KeyboardLayout.isBlack($0) && geometry.keyRect($0).contains(point) }
            ?? notes.first { !KeyboardLayout.isBlack($0) && geometry.keyRect($0).contains(point) }
    }
}

/// The corner beside the waveform and the ruler: ``GutterPainter``, compact as in the Edit tab.
final class GutterBandView: TimelineBandView {
    override func draw(_ rect: CGRect) {
        guard let (ctx, _) = context(for: rect) else { return }

        GutterPainter.draw(ctx, in: rect, bounds: bounds, scale: geometry.scale, waveformHeight: geometry.waveformHeight,
                           isCompact: true)
    }
}

// MARK: - Layers

/// A flat rectangle of one colour that moves with the playhead, the frontier or the range: the
/// Mac's `FillView` as a layer, with no implicit animation.
final class TimelineFillLayer: CALayer {
    init(colour: CGColor) {
        super.init()
        backgroundColor = colour
        isHidden = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func action(forKey event: String) -> CAAction? { nil }

    func set(frame newFrame: CGRect?) {
        guard let newFrame else {
            isHidden = true
            return
        }

        isHidden = false

        if frame != newFrame {
            frame = newFrame
        }
    }
}

/// The marked range (region design §6.3): the accent band with 1 pt edges, the Mac's
/// `RangeBandView` as layers.
final class RangeBandLayer: CALayer {
    private let leftEdge = TimelineFillLayer(colour: TimelinePalette.rangeEdge)
    private let rightEdge = TimelineFillLayer(colour: TimelinePalette.rangeEdge)

    override init() {
        super.init()
        backgroundColor = TimelinePalette.rangeFill
        isHidden = true
        addSublayer(leftEdge)
        addSublayer(rightEdge)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func action(forKey event: String) -> CAAction? { nil }

    /// Over `range` across the host's height; hidden for nil.
    func place(_ range: Range<Double>?, geometry: TimelineGeometry, height: CGFloat) {
        guard let range else {
            isHidden = true
            return
        }

        let x0 = geometry.x(forSeconds: range.lowerBound)
        let x1 = geometry.x(forSeconds: range.upperBound)
        let width = max(x1 - x0, geometry.scale)

        isHidden = false
        frame = CGRect(x: x0, y: 0, width: width, height: height)
        leftEdge.set(frame: CGRect(x: 0, y: 0, width: geometry.scale, height: height))
        rightEdge.set(frame: CGRect(x: width - geometry.scale, y: 0, width: geometry.scale, height: height))
    }
}

extension PlayheadLayer {
    /// Sized for the band, drawn at the screen's scale, with the line's pixel column at `x`;
    /// hidden for nil. Without implicit animation, so it slides frame by frame.
    func place(atX x: CGFloat?, height: CGFloat, scale: CGFloat, screenScale: CGFloat) {
        guard let x else {
            isHidden = true
            return
        }

        if self.scale != scale || contentsScale != screenScale || bounds.height != height {
            self.scale = scale
            contentsScale = screenScale
            bounds = CGRect(x: 0, y: 0, width: layerWidth, height: height)
            anchorPoint = .zero
            setNeedsDisplay()
        }

        isHidden = false

        let origin = CGPoint(x: x - lineOffset, y: 0)

        if position != origin {
            position = origin
        }
    }
}
