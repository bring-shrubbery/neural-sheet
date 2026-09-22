import AppKit

/// The marked range (region design §6.3): an accent band with 1 px edges over the roll's lanes
/// and the waveform's bars, filling left to right with the region run's progress while one is in
/// flight. Positioned by its host from the geometry; laid out only when the range, the progress
/// or the frame moves. Nothing hit-tests it.
///
/// Composed of ``FillView``s rather than a `draw(_:)`, like the wash and the marquee: a range this
/// wide would otherwise need a backing store as wide as the whole timeline, which a long range at
/// a high zoom can push past CALayer's usual tile limit — the "layer the width of the content"
/// shape AGENTS.md's band-window rule exists to avoid.
final class RangeBandView: NSView {
    private let fill = FillView(colour: TimelinePalette.rangeFill)
    private let progressFill = FillView(colour: TimelinePalette.rangeProgress)
    private let leftEdge = FillView(colour: TimelinePalette.rangeEdge)
    private let rightEdge = FillView(colour: TimelinePalette.rangeEdge)

    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { layoutFills() } }
    }

    /// 0…1 while a run is in flight, nil otherwise.
    var progress: Float? {
        didSet { if progress != oldValue { layoutFills() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        addSubview(fill)
        addSubview(progressFill)
        addSubview(leftEdge)
        addSubview(rightEdge)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Bottom to top: the fill, its progress over it, and the two edges on top — the order
    /// `draw(_:)` used to paint them in.
    private func layoutFills() {
        fill.set(frame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))

        if let progress {
            let width = (bounds.width * CGFloat(min(max(progress, 0), 1))).rounded()
            progressFill.isHidden = false
            progressFill.set(frame: CGRect(x: 0, y: 0, width: width, height: bounds.height))
        } else {
            progressFill.isHidden = true
        }

        leftEdge.set(frame: CGRect(x: 0, y: 0, width: scale, height: bounds.height))
        rightEdge.set(frame: CGRect(x: bounds.width - scale, y: 0, width: scale, height: bounds.height))
    }

    /// Lays `band` over `range` in `host`, the host's full height. The hosts' bounds origins
    /// follow their frames (`TimelineContainerView.setFrame(_:of:)`), so the geometry's x is
    /// theirs. Hidden for nil.
    static func place(_ band: RangeBandView, range: Range<Double>?, in host: NSView, geometry: TimelineGeometry) {
        guard let range else {
            band.isHidden = true
            return
        }

        let x0 = geometry.x(forSeconds: range.lowerBound)
        let x1 = geometry.x(forSeconds: range.upperBound)
        let frame = CGRect(x: x0, y: 0, width: max(x1 - x0, geometry.scale), height: host.bounds.height)

        band.isHidden = false

        if band.frame != frame {
            band.frame = frame
            band.layoutFills()
        }
    }
}
