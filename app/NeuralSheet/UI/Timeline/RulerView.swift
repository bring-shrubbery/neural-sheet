import AppKit
import NeuralSheetCore

/// The 22 px time ruler (`TimeRuler`): absolute seconds only, a 1 px tick per division and an
/// `m:ss` label 6 px to its right. In the Edit tab it reads bars and beats off the tempo grid
/// instead (design §6.4). Nothing is drawn unless the transport can play. In the Edit tab a drag
/// marks a range; a click still seeks (region design §6.2).
final class RulerView: NSView {
    let geometry: TimelineGeometry

    var canPlay = false {
        didSet {
            if canPlay != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Bars and beats instead of seconds, in the Edit tab; nil labels seconds.
    var grid: TempoGrid?

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    /// A drag marks a range for Re-transcribe (region design §6.2). Nil in the Transcribe tab,
    /// where the press is a seek as before.
    var onRange: ((Range<Double>) -> Void)?

    /// Whether the range's ends snap to the grid; the container mirrors the editor's setting.
    var snapEnabled = false

    /// The press's x, and whether it has travelled far enough to be a drag.
    private var pressX: CGFloat?
    private var isDragging = false

    /// Authored pixels a press may wander and still be a click.
    static let dragThreshold: CGFloat = 3

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

        if let grid {
            drawBarsAndBeats(ctx, grid: grid, in: dirtyRect)
            return
        }

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
        // The band's window ends at its bounds' maxX, not at its width.
        let end = bounds.maxX

        var index = firstIndex

        while true {
            let time = Double(index) * division
            let x = CGFloat((time * pixelsPerSecond).rounded()) * k

            if x >= end || x > dirtyRect.maxX {
                break
            }

            ctx.fill(CGRect(x: x, y: 0, width: k, height: height), TimelinePalette.divTick)

            TimelineText.draw(TimeFormat.ruler(time), font: font, colour: TimelinePalette.textFaint,
                              in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                              anchor: .centredLeft, context: ctx)

            index += 1
        }
    }

    /// Design §6.4: a bar tick full height with its number, a beat tick half height with
    /// `bar.beat`; labels thinned to every 2nd, 4th, 8th… bar until they clear the minimum gap.
    private func drawBarsAndBeats(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect) {
        let k = geometry.scale
        let height = bounds.height
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let font = TimelineFonts.meta(k)
        let labelInset = 6 * k
        let labelWidth = 40 * k
        let barPixels = grid.secondsPerBeat * Double(TempoGrid.beatsPerBar) * pixelsPerSecond
        let beatPixels = grid.secondsPerBeat * pixelsPerSecond

        guard barPixels > 0 else { return }

        var barsPerLabel = 1
        while Double(barsPerLabel) * barPixels < RulerTicks.minLabelGap { barsPerLabel *= 2 }
        let labelBeats = beatPixels >= RulerTicks.minLabelGap

        // Only the lines whose tick or label can touch the exposed sliver: the label extends
        // `labelInset + labelWidth` to the right of its tick.
        let from = geometry.seconds(forX: dirtyRect.minX - labelInset - labelWidth)
        let to = geometry.seconds(forX: dirtyRect.maxX)

        for line in grid.lines(from: max(0, from), to: to, division: .quarter) {
            let x = CGFloat((line.seconds * pixelsPerSecond).rounded()) * k

            guard x < bounds.maxX else { break }

            let position = grid.barBeat(at: line.seconds + 1e-6)

            switch line.kind {
            case .bar:
                ctx.fill(CGRect(x: x, y: 0, width: k, height: height), TimelinePalette.divStrong)

                // A floored remainder: bars before the downbeat (0, −1…) keep the same cadence.
                if (((position.bar - 1) % barsPerLabel) + barsPerLabel) % barsPerLabel == 0 {
                    TimelineText.draw("\(position.bar)", font: font, colour: TimelinePalette.textBright,
                                      in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                                      anchor: .centredLeft, context: ctx)
                }

            case .beat:
                ctx.fill(CGRect(x: x, y: height / 2, width: k, height: height / 2), TimelinePalette.divOctave)

                if labelBeats {
                    TimelineText.draw(grid.barBeatLabel(at: line.seconds + 1e-6), font: font, colour: TimelinePalette.textFaint,
                                      in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                                      anchor: .centredLeft, context: ctx)
                }

            case .division:
                break
            }
        }
    }

    // MARK: - Mouse

    /// The first click on the timeline while the note card is key is a click, not a focus change.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A field that had the keyboard commits and lets go, so Space is the transport's again.
        window?.makeFirstResponder(nil)

        let x = convert(event.locationInWindow, from: nil).x

        guard onRange != nil else {
            // The Transcribe tab: the press is the seek, as it always was.
            onSeek?(geometry.seconds(forX: x))
            return
        }

        pressX = x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX, onRange != nil else { return }

        let x = convert(event.locationInWindow, from: nil).x

        if !isDragging, abs(x - pressX) < RulerView.dragThreshold * geometry.scale { return }

        isDragging = true
        onRange?(range(from: pressX, to: x))
    }

    /// A press that never became a drag is the click it always was: a seek.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressX = nil
            isDragging = false
        }

        guard let pressX else { return }

        if isDragging {
            onRange?(range(from: pressX, to: convert(event.locationInWindow, from: nil).x))
        } else {
            onSeek?(geometry.seconds(forX: pressX))
        }
    }

    /// The seconds between two x's, in order, both ends snapped when the grid snaps, clamped to
    /// the take. The model refuses a sliver, so a drag that snaps to one line clears the range.
    private func range(from a: CGFloat, to b: CGFloat) -> Range<Double> {
        var lower = geometry.seconds(forX: min(a, b))
        var upper = geometry.seconds(forX: max(a, b))

        if snapEnabled, let grid {
            lower = grid.snap(lower)
            upper = grid.snap(upper)
        }

        lower = min(max(lower, 0), geometry.duration)
        upper = min(max(upper, lower), geometry.duration)

        return lower ..< upper
    }
}

/// The 46 px column beside the waveform and the ruler (`TimelineGutter`): the amplitude scale,
/// each label centred on the exact y its amplitude maps to. The ruler's share is deliberately empty.
/// Beside the Edit tab's strip there is no room for the scale, so only the rules are drawn.
final class GutterView: NSView {
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The waveform band's height in authored pixels; the container keeps it in step with the
    /// geometry, which this view does not hold.
    var waveformHeight: CGFloat = TimelineMetrics.waveformHeight {
        didSet {
            if waveformHeight != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Beside the Edit tab's strip: no amplitude labels.
    var isCompact = false {
        didSet {
            if isCompact != oldValue {
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
        let bandHeight = waveformHeight * k

        ctx.fill(rect.intersection(bounds), TimelinePalette.bgGutter)
        ctx.fill(CGRect(x: bounds.width - k, y: 0, width: k, height: bounds.height), TimelinePalette.divStrong)
        ctx.fill(CGRect(x: 0, y: bandHeight - k, width: bounds.width, height: k), TimelinePalette.divSoft)
        ctx.fill(CGRect(x: 0, y: bounds.height - k, width: bounds.width, height: k), TimelinePalette.divSoft)

        guard !isCompact else { return }

        let font = TimelineFonts.scaleLabel(k)
        let labelHeight = 9 * k
        let labelWidth = bounds.width - 6 * k
        let centreY = waveformHeight * 0.5 + 0.5

        func labelRect(amplitude: CGFloat) -> CGRect {
            let y = (centreY - amplitude * TimelineMetrics.waveformAmpHalfSpan) * k

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
