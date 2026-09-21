import AppKit

/// The marked range (region design §6.3): an accent band with 1 px edges over the roll's lanes
/// and the waveform's bars, filling left to right with the region run's progress while one is in
/// flight. Positioned by its host from the geometry; repainted only when the range, the progress
/// or the frame moves. Nothing hit-tests it.
final class RangeBandView: NSView {
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { needsDisplay = true } }
    }

    /// 0…1 while a run is in flight, nil otherwise.
    var progress: Float? {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.fill(bounds, TimelinePalette.rangeFill)

        if let progress {
            let width = (bounds.width * CGFloat(min(max(progress, 0), 1))).rounded()
            ctx.fill(CGRect(x: bounds.minX, y: 0, width: width, height: bounds.height), TimelinePalette.rangeProgress)
        }

        ctx.fill(CGRect(x: bounds.minX, y: 0, width: scale, height: bounds.height), TimelinePalette.rangeEdge)
        ctx.fill(CGRect(x: bounds.maxX - scale, y: 0, width: scale, height: bounds.height), TimelinePalette.rangeEdge)
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
            band.needsDisplay = true
        }
    }
}
