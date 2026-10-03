import NeuralSheetCore
import QuartzCore
import SwiftUI
import UIKit

/// The take's waveform on the Transcribe screen, the whole take across the width, drawn by the
/// Mac's waveform painter (`WaveformView+Drawing.swift`) over a geometry zoomed to fit: the same
/// 3-of-4 pt bars, panel and centre line as the timeline's strip. While a take is recording it
/// draws the live peaks, the take so far filling the width.
struct WaveformStrip: UIViewRepresentable {
    let peaks: WaveformPeaks?
    /// Redraws every frame, for the live peaks of a take in progress.
    var live = false

    func makeUIView(context: Context) -> WaveformStripView {
        WaveformStripView()
    }

    func updateUIView(_ view: WaveformStripView, context: Context) {
        view.peaks = peaks
        view.isLive = live
        view.setNeedsDisplay()
    }
}

/// A `UIView` over ``WaveformPainter``: the whole of `peaks` across its bounds.
final class WaveformStripView: UIView {
    private let geometry = TimelineGeometry()

    var peaks: WaveformPeaks?

    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }

            link?.invalidate()
            link = nil

            if isLive, window != nil { startLink() }
        }
    }

    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isAccessibilityElement = false
        geometry.scale = 1
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        link?.invalidate()
        link = nil

        if isLive, window != nil { startLink() }
    }

    /// 30 Hz while recording, through a proxy so the link never keeps the view alive.
    private func startLink() {
        let proxy = WaveformStripLinkProxy()
        proxy.target = self

        let link = CADisplayLink(target: proxy, selector: #selector(WaveformStripLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // The take fills the width: the zoom at which its seconds span the bounds. The band is the
        // whole view tall, ±1.0 at the Transcribe tab's proportion of it.
        let seconds = Double(peaks?.sampleCount ?? 0) / TimelineMetrics.peakSampleRate
        geometry.zoom = seconds > 0 ? Double(bounds.width) / (ZoomMath.basePixelsPerSecond * seconds) : 1
        geometry.duration = seconds
        geometry.viewportWidth = bounds.width
        geometry.waveformHeight = bounds.height
        geometry.waveformAmpHalfSpan = bounds.height * TimelineMetrics.waveformAmpHalfSpan / TimelineMetrics.waveformHeight

        WaveformPainter.draw(ctx, in: rect.intersection(bounds), bounds: bounds, geometry: geometry, peaks: peaks,
                             isCompact: true, isFileOver: false)
    }
}

/// The live strip's link target: weak on the view.
final class WaveformStripLinkProxy: NSObject {
    weak var target: WaveformStripView?

    @objc func fire(_ link: CADisplayLink) {
        target?.setNeedsDisplay()
    }
}
