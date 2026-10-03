import AppKit
import NeuralSheetCore

/// The tempo map on the ruler (tempo map design §4): a flag at each change after the first, in
/// both tabs, labelled with its tempo and with its meter where that changes too ("90 · 3/4"). The
/// flag is the marker's hit area: a click on it opens the change's card, and a right-click
/// anywhere on the ruler opens the card for the bar under the pointer.
extension RulerView {
    struct TempoFlag: Equatable {
        var bar: Int
        /// The label's box at the top of the ruler, its left edge on the change.
        var frame: CGRect
        var label: String
    }

    static let flagHeight: CGFloat = 11
    static let flagPadX: CGFloat = 4

    /// One flag per change after the first, left to right.
    func tempoFlags() -> [TempoFlag] {
        guard canPlay, let tempoMap, tempoMap.segments.count > 1 else { return [] }

        let k = geometry.scale
        let font = TimelineFonts.meta(k)
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        var previous = tempoMap.segments[0]
        var flags: [TempoFlag] = []

        for (seconds, segment) in tempoMap.changes {
            var label = MusicXMLWriter.tempoText(segment.bpm)
            if segment.timeSignature != previous.timeSignature { label += " · \(segment.timeSignature.label)" }

            let x = CGFloat((seconds * pixelsPerSecond).rounded()) * k
            let width = TimelineText.width(label, font: font) + 2 * RulerView.flagPadX * k

            flags.append(TempoFlag(bar: segment.startBar, frame: CGRect(x: x, y: 0, width: width, height: RulerView.flagHeight * k),
                                   label: label))
            previous = segment
        }

        return flags
    }

    /// The flag under `point`, the later one where two overlap (it is drawn on top).
    func tempoFlag(at point: CGPoint) -> TempoFlag? {
        tempoFlags().last { $0.frame.contains(point) }
    }

    /// Each flag touching the exposed sliver: a full-height stem on the change, then the label.
    func drawTempoFlags(_ ctx: CGContext, in dirtyRect: CGRect) {
        let k = geometry.scale
        let font = TimelineFonts.meta(k)

        for flag in tempoFlags() where flag.frame.maxX >= dirtyRect.minX && flag.frame.minX <= dirtyRect.maxX {
            ctx.fill(flag.frame, TimelinePalette.tempoFlag)
            ctx.fill(CGRect(x: flag.frame.minX, y: 0, width: k, height: bounds.height), TimelinePalette.tempoStem)
            TimelineText.draw(flag.label, font: font, colour: TimelinePalette.tempoLabel,
                              in: flag.frame.insetBy(dx: RulerView.flagPadX * k, dy: 0), anchor: .centredLeft, context: ctx)
        }
    }

    /// The card for the bar under the pointer, or the flag's bar on a flag.
    override func rightMouseDown(with event: NSEvent) {
        guard canPlay, let tempoMap, let onTempoCard else {
            super.rightMouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let bar = tempoFlag(at: point)?.bar ?? tempoMap.bar(atSeconds: max(0, geometry.seconds(forX: point.x)))

        onTempoCard(event.locationInWindow, bar)
    }
}
