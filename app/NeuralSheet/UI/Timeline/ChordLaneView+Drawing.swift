import CoreGraphics
import NeuralSheetCore

/// What the chord lane draws (chord symbols design §2), apart from any view: each symbol 4 px
/// right of a faint tick at its start, clipped at the next one, in the ruler's face a size up;
/// the pressed symbol's tick in the accent, and a dragged one where the drag has it.
/// ``ChordLaneView`` on the Mac and the iPhone and iPad app's lane draw through it (iOS app
/// design §2).
struct ChordLanePainter {
    static let height: CGFloat = 20
    static let inset: CGFloat = 4

    let geometry: TimelineGeometry
    /// The list on show, in time order, and each event's text.
    var chords: [ChordEvent]
    var labels: [String]
    /// The symbol being pressed, and where a drag has it now.
    var pressedIndex: Int?
    var draggedSeconds: Double?

    /// Where event `index` starts on show: the drag's spot for the one being dragged.
    func seconds(at index: Int) -> Double {
        if pressedIndex == index, let draggedSeconds { return draggedSeconds }

        return chords[index].seconds
    }

    /// Where the label of event `index` may run to: the next event's start (in time, the drag
    /// included), or the band's end.
    func labelEnd(at index: Int, bounds: CGRect) -> CGFloat {
        guard draggedSeconds != nil, pressedIndex != nil else {
            return index + 1 < chords.count ? geometry.x(forSeconds: chords[index + 1].seconds) : bounds.maxX
        }

        let start = seconds(at: index)
        var end = bounds.maxX

        for other in chords.indices where other != index {
            let seconds = seconds(at: other)
            if seconds > start { end = min(end, geometry.x(forSeconds: seconds)) }
        }

        return end
    }

    func draw(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        let k = geometry.scale
        let height = bounds.height
        let font = TimelineFonts.chord(k)

        ctx.fill(dirtyRect, TimelinePalette.bgPanel)
        ctx.fill(CGRect(x: dirtyRect.minX, y: height - k, width: dirtyRect.width, height: k), TimelinePalette.divSoft)

        for index in chords.indices where index < labels.count {
            let x = (geometry.x(forSeconds: seconds(at: index)) / k).rounded() * k
            let end = labelEnd(at: index, bounds: bounds)

            guard end >= dirtyRect.minX, x <= dirtyRect.maxX else { continue }

            let isPressed = pressedIndex == index
            ctx.fill(CGRect(x: x, y: 0, width: k, height: height), isPressed ? TimelinePalette.tempoStem : TimelinePalette.divTick)

            let box = CGRect(x: x + ChordLanePainter.inset * k, y: 0, width: max(0, end - x - ChordLanePainter.inset * k),
                             height: height)

            guard box.width > 0 else { continue }

            ctx.saveGState()
            ctx.clip(to: box)
            TimelineText.draw(labels[index], font: font,
                              colour: chords[index].chord == nil ? TimelinePalette.textFaint : TimelinePalette.textBright,
                              in: box, anchor: .centredLeft, context: ctx)
            ctx.restoreGState()
        }
    }
}
