import AppKit
import CoreText
import NeuralSheetCore

/// The chords of a notation staff (score design §5): heads with seconds shifted, ledger lines,
/// accidentals, dots, the stem and its flags; the time signature and the tempo mark beside them.
extension ScoreRenderer {
    /// Up when the chord sits in the lower half of the staff.
    static func stemUp(_ piece: ScorePiece) -> Bool {
        guard !piece.notes.isEmpty else { return true }

        let mean = Double(piece.notes.map(\.step).reduce(0, +)) / Double(piece.notes.count)

        return mean < 4
    }

    func drawChord(_ piece: ScorePiece, x: CGFloat, row: ScoreSystemLayout.StaffRow, in ctx: CGContext) {
        let ink = style.ink
        let stemUp = ScoreRenderer.stemUp(piece)
        let whole = piece.type == "whole"

        // Seconds in a chord: a note a step above a placed note moves right of it.
        var shifted: [Bool] = []
        var previousStep: Int?
        var previousShifted = false
        for note in piece.notes {
            let shift = previousStep.map { note.step - $0 == 1 } == true && !previousShifted
            shifted.append(shift)
            previousStep = note.step
            previousShifted = shift
        }

        var accidentalColumn = 0

        for (index, note) in piece.notes.enumerated() {
            let y = row.bottomLineY - CGFloat(note.step) * sp / 2
            let headX = x + (shifted[index] ? ScoreGlyphs.headWidth * sp : 0)

            // Ledger lines on the even steps outside the staff.
            if note.step < 0 || note.step > 8 {
                let below = note.step < 0
                // From the first line outside the staff to the note's own line, or the line
                // just inside a note on a space.
                for ledger in stride(from: below ? -2 : 10, through: note.step, by: below ? -2 : 2) {
                    let ledgerY = row.bottomLineY - CGFloat(ledger) * sp / 2
                    ctx.fill(CGRect(x: headX - 0.95 * sp, y: ledgerY - pixel / 2, width: 1.9 * sp, height: pixel), style.line)
                }
            }

            ScoreGlyphs.drawHead(note.head, hollow: piece.isHollow, whole: whole, centre: CGPoint(x: headX, y: y), sp: sp, colour: ink, context: ctx)

            if let accidental = note.accidental {
                let accidentalX = x - (1.2 + CGFloat(accidentalColumn) * 0.9) * sp
                ScoreGlyphs.drawAccidental(accidental, x: accidentalX, y: y, sp: sp, colour: ink, context: ctx)
                accidentalColumn += 1
            }

            for dot in 0..<piece.dots {
                // On the space above a line note.
                let dotY = note.step % 2 == 0 ? y - 0.5 * sp : y
                let dotX = headX + (0.95 + CGFloat(dot) * 0.5) * sp
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: CGRect(x: dotX, y: dotY - 0.2 * sp, width: 0.4 * sp, height: 0.4 * sp))
            }
        }

        guard piece.hasStem, let lowest = piece.notes.first, let highest = piece.notes.last else { return }

        let lowY = row.bottomLineY - CGFloat(lowest.step) * sp / 2
        let highY = row.bottomLineY - CGFloat(highest.step) * sp / 2
        let stemWidth = max(pixel, 0.13 * sp)
        let stemX = stemUp ? x + ScoreGlyphs.headWidth * sp / 2 - stemWidth : x - ScoreGlyphs.headWidth * sp / 2
        let end = stemUp ? highY - 3.5 * sp : lowY + 3.5 * sp
        let stemRect = stemUp
            ? CGRect(x: stemX, y: end, width: stemWidth, height: lowY - end)
            : CGRect(x: stemX, y: highY, width: stemWidth, height: end - highY)

        ctx.fill(stemRect, ink)
        ScoreGlyphs.drawFlags(count: piece.flags, stemEnd: CGPoint(x: stemUp ? stemX + stemWidth : stemX, y: end),
                              stemUp: stemUp, sp: sp, colour: ink, context: ctx)
    }

    func drawTimeSignature(_ meter: TimeSignature, x: CGFloat, bottomLineY: CGFloat, colour: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(600) as CFString, 2.6 * sp, nil)
        let upper = CGRect(x: x, y: bottomLineY - 4 * sp, width: 2 * sp, height: 2 * sp)
        let lower = CGRect(x: x, y: bottomLineY - 2 * sp, width: 2 * sp, height: 2 * sp)

        TimelineText.draw("\(meter.numerator)", font: font, colour: colour, in: upper, anchor: .centred, context: ctx)
        TimelineText.draw("\(meter.denominator)", font: font, colour: colour, in: lower, anchor: .centred, context: ctx)
    }

    /// The beat unit the meter implies and its count, "♩ = 120", or "♩. = 80" in 6/8 at a
    /// quarter-note 120 (tempo map design §2).
    func drawTempo(_ bar: ScoreBar, x: CGFloat, y: CGFloat, in ctx: CGContext) {
        let ink = style.ink
        let unit = bar.timeSignature.metronomeUnit
        let head = CGPoint(x: x + 0.6 * sp, y: y)
        ScoreGlyphs.drawHead(.normal, hollow: false, whole: false, centre: head, sp: sp * 0.8, colour: ink, context: ctx)
        ctx.fill(CGRect(x: head.x + 0.42 * sp, y: y - 2.6 * sp, width: max(1, 0.1 * sp), height: 2.6 * sp), ink)

        var textX = head.x + 1.2 * sp

        if unit.dotted {
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: head.x + 0.75 * sp, y: y - 0.45 * sp, width: 0.35 * sp, height: 0.35 * sp))
            textX += 0.5 * sp
        }

        let font = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.4 * sp, nil)
        TimelineText.draw("= \(MusicXMLWriter.tempoText(bar.bpm / unit.quarters))", font: font, colour: ink,
                          in: CGRect(x: textX, y: y - 1.5 * sp, width: 10 * sp, height: 2 * sp),
                          anchor: .centredLeft, context: ctx)
    }
}
