import CoreGraphics
import CoreText
import NeuralSheetCore

/// A chord symbol as drawn, for the right-click that opens its card.
struct ChordHit: Equatable {
    /// The event's index in the project's chord list.
    var index: Int
    var frame: CGRect
    var text: String
}

/// The chord symbols over the top staff of each system (chord symbols design §2), in the
/// score's text face: each at its position in its measure, its baseline two staff spaces above
/// the highest ink in its column (ledger lines and stems included) and never lower than that
/// over the top line, right of a tempo mark it would run into, and left out where it would
/// overlap the symbol before it.
extension ScoreRenderer {
    var chordFont: CTFont { CTFontCreateWithName(Fonts.sansName(600) as CFString, 1.6 * sp, nil) }

    /// Where each of the system's symbols goes; empty when the sheet hides them.
    func chordHits(_ system: ScoreSystemLayout.System) -> [ChordHit] {
        guard arrangement.sheet.showsChords, !document.chords.isEmpty, let top = system.rows.first else { return [] }

        let font = chordFont
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        var hits: [ChordHit] = []
        var previousEnd = -CGFloat.infinity

        for box in system.measures {
            for chord in document.chords.inMeasure(box.index) {
                var x = box.x(forUnits: Double(chord.units)) - 0.5 * sp
                let width = TimelineText.width(chord.text, font: font)

                // A tempo mark at the measure's start keeps its corner: the symbol goes past it.
                if let tempoEnd = tempoMarkEnd(box) { x = max(x, tempoEnd + 0.4 * sp) }

                guard x >= previousEnd + 0.6 * sp else { continue }

                let baseline = inkTop(row: top, box: box, from: x, to: x + width) - 2 * sp
                let frame = CGRect(x: x, y: baseline - ascent, width: width, height: ascent + descent)

                hits.append(ChordHit(index: chord.index, frame: frame, text: chord.text))
                previousEnd = frame.maxX
            }
        }

        return hits
    }

    func drawChordSymbols(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        let font = chordFont

        for hit in chordHits(system) {
            TimelineText.draw(hit.text, font: font, colour: style.ink, in: hit.frame, anchor: .topLeft, context: ctx)
        }
    }

    /// The right edge of the tempo mark the renderer draws at the start of `box`, or nil.
    private func tempoMarkEnd(_ box: ScoreSystemLayout.MeasureBox) -> CGFloat? {
        guard arrangement.sheet.showsTempo, box.index < document.bars.count, document.bars[box.index].showsTempo else { return nil }

        let bar = document.bars[box.index]
        let unit = bar.timeSignature.metronomeUnit
        let font = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.4 * sp, nil)
        let text = "= \(Formats.tempo(bar.bpm / unit.quarters))"

        return box.contentX + (1.8 + (unit.dotted ? 0.5 : 0)) * sp + TimelineText.width(text, font: font)
    }

    /// The highest ink of the row's pieces in `box` whose heads fall between `from` and `to`:
    /// the top line at the lowest, a head above it with its ledger lines, an up stem's end.
    private func inkTop(row: ScoreSystemLayout.StaffRow, box: ScoreSystemLayout.MeasureBox, from: CGFloat, to: CGFloat) -> CGFloat {
        let measure = box.index
        var top = row.topLineY

        guard case let .staff(staffIndex, _) = row.kind else { return top }

        let part = document.parts[row.partIndex]

        guard staffIndex < part.staves.count, measure < part.staves[staffIndex].measures.count else { return top }

        for piece in part.staves[staffIndex].measures[measure].pieces where !piece.isRest {
            let x = box.x(forUnits: Double(piece.startUnits))

            guard x + sp >= from, x - sp <= to, let highest = piece.notes.last else { continue }

            let headY = row.bottomLineY - CGFloat(highest.step) * sp / 2
            let stemEnd = piece.hasStem && ScoreRenderer.stemUp(piece) ? headY - 3.5 * sp : headY - 0.5 * sp

            top = min(top, stemEnd)
        }

        return top
    }
}
