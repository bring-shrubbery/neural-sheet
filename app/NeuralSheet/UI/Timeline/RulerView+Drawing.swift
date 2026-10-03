import CoreGraphics
import Foundation
import NeuralSheetCore

/// What the 22 px time ruler draws (`TimeRuler`), apart from any view: absolute seconds, or bars
/// and beats off the tempo grid in the Edit tab (design §6.4), the tempo map's flags (tempo map
/// design §4) and the section markers' flags (markers and lyrics design §2). ``RulerView`` on the
/// Mac and the iPhone and iPad app's ruler both hold one (iOS app design §2).
struct RulerPainter {
    struct TempoFlag: Equatable {
        var bar: Int
        /// The label's box at the top of the ruler, its left edge on the change.
        var frame: CGRect
        var label: String
    }

    struct MarkerFlag: Equatable {
        var id: UUID
        var seconds: Double
        /// The label's box along the bottom of the ruler, its left edge on the marker.
        var frame: CGRect
        var name: String
    }

    static let flagHeight: CGFloat = 11
    static let flagPadX: CGFloat = 4

    let geometry: TimelineGeometry

    /// Nothing is drawn unless the transport can play.
    var canPlay = false

    /// Bars and beats instead of seconds, in the Edit tab; nil labels seconds.
    var grid: TempoGrid?

    /// The tempo map whose changes are flagged, in both tabs (tempo map design §4).
    var tempoMap: TempoGrid?

    /// The section markers flagged along the bottom of the ruler, in both tabs.
    var markers: [Marker] = []

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
    }

    func draw(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let height = bounds.height

        ctx.fill(dirtyRect, TimelinePalette.bgPanel)
        ctx.fill(CGRect(x: dirtyRect.minX, y: height - k, width: dirtyRect.width, height: k), TimelinePalette.divSoft)

        guard canPlay else { return }

        if let grid {
            drawBarsAndBeats(ctx, grid: grid, in: dirtyRect, bounds: bounds)
        } else {
            drawSeconds(ctx, in: dirtyRect, bounds: bounds)
        }

        drawTempoFlags(ctx, in: dirtyRect, bounds: bounds)
        drawMarkerFlags(ctx, in: dirtyRect, bounds: bounds)
    }

    /// `TimeRuler`: a tick per round division of seconds and its `m:ss` label.
    private func drawSeconds(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let height = bounds.height
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
    /// The beats are the meter's (six to a bar of 6/8) and the densest bar or beat in view sets
    /// the thinning, so a tempo change does not crowd the labels (tempo map design §2).
    private func drawBarsAndBeats(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let height = bounds.height
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let font = TimelineFonts.meta(k)
        let labelInset = 6 * k
        let labelWidth = 40 * k

        // Only the lines whose tick or label can touch the exposed sliver: the label extends
        // `labelInset + labelWidth` to the right of its tick.
        let from = geometry.seconds(forX: dirtyRect.minX - labelInset - labelWidth)
        let to = geometry.seconds(forX: dirtyRect.maxX)
        let visible = grid.segments(from: max(0, from), to: to)
        let barPixels = (visible.map(\.barSeconds).min() ?? 0) * pixelsPerSecond
        let beatPixels = (visible.map { $0.timeSignature.beatLength * 60 / $0.bpm }.min() ?? 0) * pixelsPerSecond

        guard barPixels > 0 else { return }

        var barsPerLabel = 1
        while Double(barsPerLabel) * barPixels < RulerTicks.minLabelGap { barsPerLabel *= 2 }
        let labelBeats = beatPixels >= RulerTicks.minLabelGap

        for line in grid.beatLines(from: max(0, from), to: to) {
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

    // MARK: - Tempo flags

    /// One flag per change after the first, left to right, each labelled with its tempo and with
    /// its meter where that changes too ("90 · 3/4").
    func tempoFlags() -> [TempoFlag] {
        guard canPlay, let tempoMap, tempoMap.segments.count > 1 else { return [] }

        let k = geometry.scale
        let font = TimelineFonts.meta(k)
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        var previous = tempoMap.segments[0]
        var flags: [TempoFlag] = []

        for (seconds, segment) in tempoMap.changes {
            var label = Formats.tempo(segment.bpm)
            if segment.timeSignature != previous.timeSignature { label += " · \(segment.timeSignature.label)" }

            let x = CGFloat((seconds * pixelsPerSecond).rounded()) * k
            let width = TimelineText.width(label, font: font) + 2 * RulerPainter.flagPadX * k

            flags.append(TempoFlag(bar: segment.startBar, frame: CGRect(x: x, y: 0, width: width, height: RulerPainter.flagHeight * k),
                                   label: label))
            previous = segment
        }

        return flags
    }

    /// Each flag touching the exposed sliver: a full-height stem on the change, then the label.
    private func drawTempoFlags(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let font = TimelineFonts.meta(k)

        for flag in tempoFlags() where flag.frame.maxX >= dirtyRect.minX && flag.frame.minX <= dirtyRect.maxX {
            ctx.fill(flag.frame, TimelinePalette.tempoFlag)
            ctx.fill(CGRect(x: flag.frame.minX, y: 0, width: k, height: bounds.height), TimelinePalette.tempoStem)
            TimelineText.draw(flag.label, font: font, colour: TimelinePalette.tempoLabel,
                              in: flag.frame.insetBy(dx: RulerPainter.flagPadX * k, dy: 0), anchor: .centredLeft, context: ctx)
        }
    }

    // MARK: - Marker flags

    /// One flag per marker along the lower half of the ruler, below the tempo flags' row, left to
    /// right, each clipped at the next.
    func markerFlags(bounds: CGRect) -> [MarkerFlag] {
        guard canPlay, !markers.isEmpty else { return [] }

        let k = geometry.scale
        let font = TimelineFonts.meta(k)
        let height = RulerPainter.flagHeight * k
        let y = bounds.height - height - k
        let xs = markers.map { geometry.x(forSeconds: $0.seconds).rounded() }

        return markers.enumerated().map { index, marker in
            let x = xs[index]
            let natural = (marker.name.isEmpty ? 0 : TimelineText.width(marker.name, font: font)) + 2 * RulerPainter.flagPadX * k
            let room = index + 1 < xs.count ? max(k, xs[index + 1] - x) : natural

            return MarkerFlag(id: marker.id, seconds: marker.seconds,
                              frame: CGRect(x: x, y: y, width: min(natural, room), height: height), name: marker.name)
        }
    }

    /// Each flag touching the exposed sliver: the stem the ruler's full height, the label box,
    /// the name inside it, clipped to the box.
    private func drawMarkerFlags(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let font = TimelineFonts.meta(k)

        for flag in markerFlags(bounds: bounds) where flag.frame.maxX >= dirtyRect.minX && flag.frame.minX <= dirtyRect.maxX {
            ctx.fill(flag.frame, TimelinePalette.markerFlag)
            ctx.fill(CGRect(x: flag.frame.minX, y: 0, width: k, height: bounds.height), TimelinePalette.markerStem)

            guard !flag.name.isEmpty else { continue }

            ctx.saveGState()
            ctx.clip(to: flag.frame)
            TimelineText.draw(flag.name, font: font, colour: TimelinePalette.markerLabel,
                              in: flag.frame.insetBy(dx: RulerPainter.flagPadX * k, dy: 0), anchor: .centredLeft, context: ctx)
            ctx.restoreGState()
        }
    }
}

/// What the 46 px column beside the waveform and the ruler draws (`TimelineGutter`): the
/// amplitude scale, each label centred on the exact y its amplitude maps to. The ruler's share is
/// deliberately empty. Beside the Edit tab's strip there is no room for the scale, so only the
/// rules are drawn.
enum GutterPainter {
    static func draw(_ ctx: CGContext, in rect: CGRect, bounds: CGRect, scale k: CGFloat, waveformHeight: CGFloat,
                     isCompact: Bool) {
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
