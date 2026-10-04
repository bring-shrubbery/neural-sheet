import AppKit
import NeuralSheetCore
import SwiftUI

/// The captured take's waveform (Audio Unit design §5, item B), the whole take fitted to the
/// view's width and drawn by the shared ``WaveformPainter`` the Mac and iOS strips call. The Mac's
/// `WaveformView` is not reused: it carries the timeline's playhead, wash, range band and seek,
/// which the plugin has no use for until sub-issue D.
final class TakeWaveformNSView: NSView {
    var peaks: WaveformPeaks? {
        didSet { needsDisplay = true }
    }

    /// Seconds of audio, which sets the zoom that fits the take to the width.
    var duration: Double = 0 {
        didSet { needsDisplay = true }
    }

    private let geometry = TimelineGeometry()

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Authored pixels are points here, and the Transcribe tab's 126 px band is the
        // amplitude scale, stretched to the view's height.
        geometry.scale = 1
        geometry.duration = duration
        geometry.viewportWidth = bounds.width
        geometry.waveformHeight = bounds.height
        geometry.waveformAmpHalfSpan = TimelineMetrics.waveformAmpHalfSpan * bounds.height
            / TimelineMetrics.waveformHeight
        geometry.zoom = duration > 0 ? Double(bounds.width) / (ZoomMath.basePixelsPerSecond * duration) : 1

        WaveformPainter.draw(ctx, in: dirtyRect.intersection(bounds), bounds: bounds, geometry: geometry,
                             peaks: peaks, isCompact: true, isFileOver: false)
    }
}

/// ``TakeWaveformNSView`` in the SwiftUI view.
struct TakeWaveform: NSViewRepresentable {
    let take: SourceAudio

    func makeNSView(context: Context) -> TakeWaveformNSView {
        TakeWaveformNSView()
    }

    func updateNSView(_ view: TakeWaveformNSView, context: Context) {
        if view.peaks !== take.peaks { view.peaks = take.peaks }
        if view.duration != take.duration { view.duration = take.duration }
    }
}
