import AppKit
import NeuralSheetCore

/// The tempo map on the ruler (tempo map design §4): a flag at each change after the first, in
/// both tabs, labelled with its tempo and with its meter where that changes too ("90 · 3/4"). The
/// flag is the marker's hit area: a click on it opens the change's card, and a right-click
/// anywhere on the ruler opens the card for the bar under the pointer.
extension RulerView {
    typealias TempoFlag = RulerPainter.TempoFlag

    static let flagHeight = RulerPainter.flagHeight
    static let flagPadX = RulerPainter.flagPadX

    /// One flag per change after the first, left to right.
    func tempoFlags() -> [TempoFlag] {
        painter.tempoFlags()
    }

    /// The flag under `point`, the later one where two overlap (it is drawn on top).
    func tempoFlag(at point: CGPoint) -> TempoFlag? {
        tempoFlags().last { $0.frame.contains(point) }
    }

    /// The card for the bar under the pointer, or the flag's bar on a flag, with the marker
    /// whose flag is under it, if any (markers and lyrics design §2).
    override func rightMouseDown(with event: NSEvent) {
        guard canPlay, let tempoMap, let onTempoCard else {
            super.rightMouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let seconds = max(0, geometry.seconds(forX: point.x))
        let bar = tempoFlag(at: point)?.bar ?? tempoMap.bar(atSeconds: seconds)
        let marker = markerFlag(at: point)

        onTempoCard(event.locationInWindow, RulerCardTarget(bar: bar, seconds: marker?.seconds ?? seconds, markerID: marker?.id))
    }
}
