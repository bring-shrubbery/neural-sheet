import AppKit
import NeuralSheetCore

/// The 126 px waveform strip (`AudioRegion`): bars over the take's peaks, the played wash, the
/// corner label, and the dashed drop zone while there is nothing loaded. In the Edit tab it is a
/// 40 px strip (design §3.4): the same bars over a smaller span, no label, no drop zone.
///
/// As wide as the whole timeline, so `draw` only ever touches the exposed sliver: the bars are
/// anchored to absolute content pixels and read straight off the peaks pyramid under one lock.
final class WaveformView: NSView {
    let geometry: TimelineGeometry

    /// Where the peaks come from; nil draws the empty state.
    var peaks: WaveformPeaks?

    /// True while a supported file is dragged over the timeline: the drop zone lights up.
    var isFileOver = false {
        didSet {
            if isFileOver != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The Edit tab's strip: the bars only, the corner label and the drop zone withheld.
    var isCompact = false {
        didSet {
            if isCompact != oldValue {
                cornerLabel.isHidden = isCompact || (peaks?.sampleCount ?? 0) == 0
                needsDisplay = true
            }
        }
    }

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    /// The level VoiceOver reads as the strip's value, in dB (`+Accessibility`); the container's.
    var accessibilityLevel: (() -> Double)?

    let playhead = PlayheadView(drawsTriangle: true)
    let wash = FillView(colour: TimelinePalette.accentWashWave)
    let washEdge = FillView(colour: TimelinePalette.accentWashEdge)
    let rangeBand = RangeBandView(frame: .zero)
    private let cornerLabel = WaveformLabelView()

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true

        // Bottom to top: the wash and its edge sit over the bars, the label over the wash, and the
        // playhead over everything — the order `AudioRegion::paint` draws them in.
        addSubview(wash)
        addSubview(washEdge)
        addSubview(rangeBand)
        addSubview(cornerLabel)
        addSubview(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    // MARK: - Layout

    func configure() {
        let k = geometry.scale

        playhead.configure(scale: k, height: bounds.height)
        cornerLabel.scale = k
        cornerLabel.frame = CGRect(x: 10 * k, y: 10 * k, width: 200 * k, height: 12 * k)
        cornerLabel.needsDisplay = true
        rangeBand.scale = k
    }

    /// Moves the playhead and everything that hangs off it. `x` is in real points, or nil to hide.
    func setPlayhead(x: CGFloat?) {
        guard let x else {
            playhead.isHidden = true
            wash.isHidden = true
            washEdge.isHidden = true
            return
        }

        playhead.isHidden = false
        playhead.move(toX: x)

        // `if (playhead_x > 0)`: nothing is washed at the start.
        let washed = x > 0
        wash.isHidden = !washed
        washEdge.isHidden = !washed

        if washed {
            wash.set(frame: CGRect(x: 0, y: 0, width: x, height: bounds.height))
            washEdge.set(frame: CGRect(x: x - geometry.scale, y: 0, width: geometry.scale, height: bounds.height))
        }
    }

    // MARK: - Range

    /// The marked range and, while a region run is in flight, its progress (region design §6.3).
    func setRange(_ range: Range<Double>?, progress: Float?) {
        rangeBand.progress = progress
        RangeBandView.place(rangeBand, range: range, in: self, geometry: geometry)
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The corner label goes with the audio (`AudioRegion::paint` returns after the drop zone),
        // and the strip has no room for it.
        let hasAudio = (peaks?.sampleCount ?? 0) > 0
        let showLabel = hasAudio && !isCompact

        if cornerLabel.isHidden == showLabel {
            cornerLabel.isHidden = !showLabel
        }

        WaveformPainter.draw(ctx, in: rect.intersection(bounds), bounds: bounds, geometry: geometry, peaks: peaks,
                             isCompact: isCompact, isFileOver: isFileOver)
    }

    // MARK: - Empty-state layout

    /// Where the load button sits over the empty strip (`WaveformPainter`'s layout).
    static func loadButtonY(scale: CGFloat) -> CGFloat {
        WaveformPainter.loadButtonY(scale: scale)
    }

    // MARK: - Mouse

    /// The first click on the timeline while the note card is key is a click, not a focus change.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A field that had the keyboard commits and lets go, so Space is the transport's again.
        window?.makeFirstResponder(nil)

        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(geometry.seconds(forX: x))
    }
}

/// The "MIX WAVEFORM" corner label, in its own view so it sits above the played wash and below the
/// playhead, as `AudioRegion::paint` orders them. It scrolls with the content, as the original did.
private final class WaveformLabelView: NSView {
    var scale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        WaveformPainter.drawCornerLabel(ctx, in: bounds, scale: scale)
    }
}
