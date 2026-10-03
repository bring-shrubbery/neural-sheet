import CoreGraphics
import Foundation
import NeuralSheetCore

/// What the waveform strip draws (`AudioRegion`), apart from any view: bars over the take's
/// peaks, the centre line, the corner label, and the dashed drop zone while there is nothing
/// loaded. In the Edit tab a 40 px strip (design §3.4): the same bars over a smaller span, no
/// label, no drop zone. ``WaveformView`` on the Mac and the iPhone and iPad app's strips call it
/// (iOS app design §2).
///
/// As wide as the band, so `draw` only ever touches the exposed sliver: the bars are anchored to
/// absolute content pixels and read straight off the peaks pyramid under one lock.
enum WaveformPainter {
    static func draw(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect, geometry: TimelineGeometry,
                     peaks: WaveformPeaks?, isCompact: Bool, isFileOver: Bool) {
        let k = geometry.scale
        let height = bounds.height

        ctx.fill(dirtyRect, TimelinePalette.bgPanel)
        ctx.fill(CGRect(x: dirtyRect.minX, y: height - k, width: dirtyRect.width, height: k), TimelinePalette.divSoft)

        // The drop zone is the empty Transcribe strip's; the corner label is the host's, over the
        // played wash (`drawCornerLabel`).
        let hasAudio = (peaks?.sampleCount ?? 0) > 0

        guard let peaks, hasAudio else {
            // The strip is not a drop target's face: the load button lives in the Transcribe tab.
            if !isCompact {
                drawDropZone(ctx, bounds: bounds, scale: geometry.scale, isFileOver: isFileOver)
            }

            return
        }

        // The centre line at `height / 2`, one authored pixel tall.
        ctx.fill(CGRect(x: dirtyRect.minX, y: (geometry.waveformHeight / 2).rounded(.down) * k,
                        width: dirtyRect.width, height: k), TimelinePalette.waveCentreLine)

        drawBars(ctx, peaks: peaks, geometry: geometry, from: dirtyRect.minX, to: dirtyRect.maxX)
    }

    /// `AudioRegion::_paintWaveform`: one bar per 4 px pitch over the exposed range, each spanning
    /// its whole pitch of audio, mirrored about the centre at `max(|min|, |max|)`.
    private static func drawBars(_ ctx: CGContext, peaks: WaveformPeaks, geometry: TimelineGeometry, from fromX: CGFloat,
                                 to toX: CGFloat) {
        let k = geometry.scale
        let pitch = TimelineMetrics.barPitch * k
        let barWidth = TimelineMetrics.barWidth * k
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let pitchAuthored = Double(TimelineMetrics.barPitch)
        let centreY = geometry.waveformCentreY * k
        let halfSpan = geometry.waveformAmpHalfSpan * k
        let minHeight = 1 * k

        guard pixelsPerSecond > 0 else { return }

        peaks.withReader { reader in
            let sampleCount = reader.sampleCount
            let bars = WaveformBars.visibleBars(from: fromX / pitch, to: toX / pitch, sampleCount: sampleCount,
                                                pixelsPerSecond: pixelsPerSecond, pitch: pitchAuthored)

            guard let bars else { return }

            ctx.setFillColor(TimelinePalette.wavePlayed)

            var barStart = WaveformBars.startSample(ofBar: bars.lowerBound, pixelsPerSecond: pixelsPerSecond,
                                                    pitch: pitchAuthored)

            for bar in bars {
                let nextStart = WaveformBars.startSample(ofBar: bar + 1, pixelsPerSecond: pixelsPerSecond,
                                                         pitch: pitchAuthored)
                let pair = reader.peaks(from: barStart, to: nextStart)
                barStart = nextStart

                guard !pair.isEmpty else { continue }

                let high = CGFloat(min(max(max(abs(pair.min), abs(pair.max)), -1), 1))
                let top = centreY - high * halfSpan
                let bottom = centreY + high * halfSpan
                let barHeight = max(bottom - top, minHeight)

                // Integer x keeps the bar edges crisp; the y stays fractional so the envelope reads
                // as a curve rather than a staircase.
                ctx.fill(CGRect(x: CGFloat(bar) * pitch, y: (top + bottom - barHeight) / 2,
                                width: barWidth, height: barHeight))
            }
        }
    }

    /// `AudioRegion::_paintDropZone`: the dashed panel and the hint under the load button.
    private static func drawDropZone(_ ctx: CGContext, bounds: CGRect, scale k: CGFloat, isFileOver: Bool) {
        let zone = bounds.insetBy(dx: 9 * k, dy: 9 * k)
        let corner = 8 * k

        ctx.fillRoundedRect(zone, corner: corner,
                            isFileOver ? TimelinePalette.ctaFill : TimelinePalette.dropZoneFill)

        // Dashed rather than solid: a solid outline this size reads as a panel that is part of the
        // layout, and this one goes away as soon as anything is loaded.
        let outline = zone.insetBy(dx: 0.5 * k, dy: 0.5 * k)
        ctx.saveGState()
        ctx.addPath(WaveformPainter.roundedRectangleClockwise(outline, corner: corner))
        ctx.setLineWidth(1 * k)
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [4 * k, 4 * k])
        ctx.setStrokeColor(isFileOver ? TimelinePalette.ctaBorder : TimelinePalette.dropZoneBorder)
        ctx.strokePath()
        ctx.restoreGState()

        let hint = WaveformPainter.dropHintRect(width: bounds.width, scale: k)

        TimelineText.draw(String(localized: "OR DROP A FILE HERE", comment: "The empty waveform, under the Load audio file button"), font: TimelineFonts.meta(k), colour: TimelinePalette.textScale,
                          in: hint, anchor: .centred, tracking: 0.06 * Fonts.Size.meta * k, context: ctx)
    }

    /// `juce::Path::addRoundedRectangle`'s order — from the top-left corner's end, clockwise — so
    /// the dashes start where JUCE's do.
    private static func roundedRectangleClockwise(_ r: CGRect, corner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let c = min(corner, r.width / 2, r.height / 2)

        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + c), radius: c)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - c, y: r.maxY), radius: c)
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - c), radius: c)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + c, y: r.minY), radius: c)
        path.closeSubpath()

        return path
    }

    // MARK: - Empty-state layout

    static let loadButtonHeight: CGFloat = 32
    static let dropHintGap: CGFloat = 9
    static let dropHintHeight: CGFloat = 12

    /// The button and the hint below it are centred as a column, so the button's own centre sits
    /// slightly above the region's (`AudioRegion::resized`). Authored integer arithmetic, scaled.
    /// Against the Transcribe tab's height: the empty state never shows in the Edit tab's strip.
    static func loadButtonY(scale: CGFloat) -> CGFloat {
        let column = loadButtonHeight + dropHintGap + dropHintHeight

        return ((TimelineMetrics.waveformHeight - column) / 2).rounded(.down) * scale
    }

    static func dropHintRect(width: CGFloat, scale: CGFloat) -> CGRect {
        let column = loadButtonHeight + dropHintGap + dropHintHeight
        let top = ((TimelineMetrics.waveformHeight - column) / 2).rounded(.down) + column - dropHintHeight

        return CGRect(x: 0, y: top * scale, width: width, height: dropHintHeight * scale)
    }

    /// The "MIX WAVEFORM" corner label, drawn by its own view or layer so it sits above the
    /// played wash and below the playhead, as `AudioRegion::paint` orders them.
    static func drawCornerLabel(_ ctx: CGContext, in bounds: CGRect, scale: CGFloat) {
        TimelineText.draw(String(localized: "MIX WAVEFORM", comment: "The waveform's corner label"), font: TimelineFonts.meta(scale), colour: TimelinePalette.textScale,
                          in: bounds, anchor: .topLeft, tracking: 0.1 * Fonts.Size.meta * scale, context: ctx)
    }
}

/// `WaveformBars`: where the bars fall along the timeline, anchored to absolute content pixels so
/// scrolling reveals rather than re-slices. Bar i covers samples `[startSample(i), startSample(i + 1))`.
enum WaveformBars {
    /// The first sample of a bar, from the index rather than by accumulating a per-bar count: that
    /// count is fractional at most zooms, and rounding it per bar would leave gaps that drop audio.
    static func startSample(ofBar bar: Int, pixelsPerSecond: Double, pitch: Double) -> Int {
        guard pixelsPerSecond > 0, bar > 0 else { return 0 }

        return Int(Double(bar) * pitch * TimelineMetrics.peakSampleRate / pixelsPerSecond)
    }

    /// The bars overlapping `[from, to)` in bar units, limited to those with audio in them.
    static func visibleBars(from: CGFloat, to: CGFloat, sampleCount: Int, pixelsPerSecond: Double, pitch: Double)
        -> ClosedRange<Int>?
    {
        guard pitch > 0, pixelsPerSecond > 0, sampleCount > 0, to > from else { return nil }

        let first = max(0, Int(from.rounded(.down)))
        let last = Int(to.rounded(.up)) - 1

        guard last >= first else { return nil }

        // The last bar that starts inside the audio, walked to agree exactly with `startSample`.
        var highest = Int(Double(sampleCount) * pixelsPerSecond / (TimelineMetrics.peakSampleRate * pitch))

        while highest > 0, startSample(ofBar: highest, pixelsPerSecond: pixelsPerSecond, pitch: pitch) >= sampleCount {
            highest -= 1
        }

        while startSample(ofBar: highest + 1, pixelsPerSecond: pixelsPerSecond, pitch: pitch) < sampleCount {
            highest += 1
        }

        let end = min(last, highest)

        return end >= first ? first...end : nil
    }
}
