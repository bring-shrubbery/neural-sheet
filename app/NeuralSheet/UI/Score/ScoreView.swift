import AppKit
import CoreText
import NeuralSheetCore

/// The page (score design §5): a ``ScoreLayout`` drawn — staves, bar lines, clefs, signatures,
/// pieces, ties, part names, measure numbers, the tempo mark — with the cursor as a subview so
/// the playhead moves without a repaint. Sized by its container to the layout's height.
final class ScoreView: NSView {
    var document = ScoreDocument.empty
    var layout: ScoreLayout?

    /// The click seeks; the container owns the model.
    var onSeek: ((Int, Double) -> Void)?

    let cursor = FillView(colour: ScorePalette.cursor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(cursor)
        cursor.isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Puts the cursor at `units` into measure `measure`, or hides it.
    func placeCursor(measure: Int?, units: Double) {
        guard let layout, let measure, let (system, box) = layout.box(forMeasure: measure) else {
            cursor.isHidden = true
            return
        }

        let x = box.x(forUnits: units)
        let top = system.staffTop - layout.sp
        let bottom = system.staffBottom + layout.sp

        cursor.isHidden = false
        cursor.set(frame: CGRect(x: (x - 0.75).rounded(), y: top, width: 1.5, height: bottom - top))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        guard let layout else { return }

        let point = convert(event.locationInWindow, from: nil)

        if let hit = layout.hitTest(point) {
            onSeek?(hit.measure, hit.units)
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.fill(rect.intersection(bounds), ScorePalette.paper)

        guard let layout else { return }

        let sp = layout.sp
        let pixel = max(1, (sp / 8).rounded())

        for system in layout.systems where system.frame.insetBy(dx: 0, dy: -8 * sp).intersects(rect) {
            drawSystem(system, layout: layout, sp: sp, pixel: pixel, in: ctx)
        }
    }

    private func drawSystem(_ system: ScoreLayout.System, layout: ScoreLayout, sp: CGFloat, pixel: CGFloat, in ctx: CGContext) {
        let ink = ScorePalette.ink
        let line = ScorePalette.line

        // Staves and the left edge joining them.
        for row in system.rows {
            for step in 0..<5 {
                let y = row.bottomLineY - CGFloat(step) * sp
                ctx.fill(CGRect(x: system.frame.minX, y: y - pixel / 2, width: system.frame.width, height: pixel), line)
            }
        }

        ctx.fill(CGRect(x: system.frame.minX, y: system.staffTop, width: pixel, height: system.staffBottom - system.staffTop), line)

        // Bar lines per staff, the final one doubled.
        let isFinalSystem = system.measures.last?.index == document.measureCount - 1

        for row in system.rows {
            let top = row.bottomLineY - 4 * sp

            for (index, box) in system.measures.enumerated() where index > 0 {
                ctx.fill(CGRect(x: box.x - pixel / 2, y: top, width: pixel, height: 4 * sp), line)
            }

            ctx.fill(CGRect(x: system.frame.maxX - pixel, y: top, width: pixel, height: 4 * sp), isFinalSystem ? ink : line)

            if isFinalSystem {
                ctx.fill(CGRect(x: system.frame.maxX - 0.5 * sp - pixel, y: top, width: pixel, height: 4 * sp), ink)
            }
        }

        // Names, clefs, signatures.
        let isFirst = system.showsTimeSignature
        let nameFont = TimelineFonts.meta(sp / 8)

        for row in system.rows {
            let part = document.parts[row.partIndex]
            let staff = part.staves[row.staffIndex]

            if row.staffIndex == 0 {
                let colour = TimelinePalette.cg(Instruments.info(forProgram: part.program).colour, alpha: 1)
                let label = isFirst ? part.name : part.abbreviation
                // The middle of the part's staves: the first staff's middle, then half the way
                // down to the last.
                let centreY = row.bottomLineY - 2 * sp + CGFloat(part.staves.count - 1) * (4 + ScoreLayout.staffGap) * sp / 2
                TimelineText.draw(label, font: nameFont, colour: colour,
                                  in: CGRect(x: 0, y: centreY - sp, width: system.frame.minX - 0.6 * sp, height: 2 * sp),
                                  anchor: .centredRight, context: ctx)
            }

            guard let first = system.measures.first else { continue }

            var x = first.x + 0.4 * sp
            ScoreGlyphs.drawClef(staff.clef, x: x, bottomLineY: row.bottomLineY, sp: sp, colour: ink, context: ctx)
            x += ScoreLayout.clefWidth * sp

            if staff.clef != .percussion {
                let accidental: Accidental = document.fifths > 0 ? .sharp : .flat
                for position in staff.clef.signaturePositions(fifths: document.fifths) {
                    let y = row.bottomLineY - CGFloat(position) * sp / 2
                    ScoreGlyphs.drawAccidental(accidental, x: x, y: y, sp: sp, colour: ink, context: ctx)
                    x += ScoreLayout.accidentalWidth * sp
                }
            } else {
                x += CGFloat(abs(document.fifths)) * ScoreLayout.accidentalWidth * sp
            }

            if isFirst {
                drawTimeSignature(x: x + 0.3 * sp, bottomLineY: row.bottomLineY, sp: sp, colour: ink, in: ctx)
            }
        }

        // Measure numbers above the top staff at the system's start; the tempo on the first.
        if let first = system.measures.first, let topRow = system.rows.first {
            let numberFont = TimelineFonts.scaleLabel(sp / 8)
            let y = topRow.bottomLineY - 4 * sp
            TimelineText.draw("\(first.index + 1)", font: numberFont, colour: ScorePalette.faint,
                              in: CGRect(x: first.x, y: y - 2.6 * sp, width: 6 * sp, height: 1.6 * sp),
                              anchor: .centredLeft, context: ctx)

            if isFirst {
                drawTempo(x: first.contentX, y: y - 3.2 * sp, sp: sp, in: ctx)
            }
        }

        // The music.
        for row in system.rows {
            let staff = document.parts[row.partIndex].staves[row.staffIndex]

            for (boxIndex, box) in system.measures.enumerated() where box.index < staff.measures.count {
                let measure = staff.measures[box.index]

                for (pieceIndex, piece) in measure.pieces.enumerated() {
                    let x = piece.isWholeMeasureRest ? (box.contentX + box.endX) / 2 : box.x(forUnits: Double(piece.startUnits))

                    if piece.isRest {
                        ScoreGlyphs.drawRest(type: piece.type, dots: piece.dots, x: x, bottomLineY: row.bottomLineY, sp: sp, colour: ink, context: ctx)
                        continue
                    }

                    drawChord(piece, x: x, row: row, sp: sp, pixel: pixel, in: ctx)

                    // Ties to whatever comes next at the same pitch.
                    let tied = piece.notes.filter(\.tiedTo)
                    guard !tied.isEmpty else { continue }

                    let nextInMeasure = pieceIndex + 1 < measure.pieces.count ? measure.pieces[pieceIndex + 1] : nil
                    let nextBox = boxIndex + 1 < system.measures.count ? system.measures[boxIndex + 1] : nil
                    let nextPiece = nextInMeasure ?? nextBox.flatMap { $0.index < staff.measures.count ? staff.measures[$0.index].pieces.first : nil }
                    let nextX: CGFloat? = nextInMeasure.map { box.x(forUnits: Double($0.startUnits)) }
                        ?? nextBox.flatMap { next in nextPiece.map { next.x(forUnits: Double($0.startUnits)) } }
                    let stemUp = ScoreView.stemUp(piece)

                    for note in tied {
                        let y = row.bottomLineY - CGFloat(note.step) * sp / 2
                        let from = CGPoint(x: x + 0.7 * sp, y: y + (stemUp ? 0.55 : -0.55) * sp)
                        let toX = (nextPiece?.notes.contains { $0.pitch == note.pitch } == true ? nextX : nil) ?? (box.endX - 0.3 * sp)
                        let to = CGPoint(x: toX - 0.7 * sp, y: from.y)
                        ScoreGlyphs.drawTie(from: from, to: to, below: stemUp, sp: sp, colour: ink, context: ctx)
                    }
                }
            }
        }
    }

    /// Up when the chord sits in the lower half of the staff.
    static func stemUp(_ piece: ScorePiece) -> Bool {
        guard !piece.notes.isEmpty else { return true }

        let mean = Double(piece.notes.map(\.step).reduce(0, +)) / Double(piece.notes.count)

        return mean < 4
    }

    private func drawChord(_ piece: ScorePiece, x: CGFloat, row: ScoreLayout.StaffRow, sp: CGFloat, pixel: CGFloat, in ctx: CGContext) {
        let ink = ScorePalette.ink
        let stemUp = ScoreView.stemUp(piece)
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
                    ctx.fill(CGRect(x: headX - 0.95 * sp, y: ledgerY - pixel / 2, width: 1.9 * sp, height: pixel), ScorePalette.line)
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

    private func drawTimeSignature(x: CGFloat, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(600) as CFString, 2.6 * sp, nil)
        let upper = CGRect(x: x, y: bottomLineY - 4 * sp, width: 2 * sp, height: 2 * sp)
        let lower = CGRect(x: x, y: bottomLineY - 2 * sp, width: 2 * sp, height: 2 * sp)

        TimelineText.draw("\(TempoGrid.beatsPerBar)", font: font, colour: colour, in: upper, anchor: .centred, context: ctx)
        TimelineText.draw("4", font: font, colour: colour, in: lower, anchor: .centred, context: ctx)
    }

    /// A quarter note and "= 120".
    private func drawTempo(x: CGFloat, y: CGFloat, sp: CGFloat, in ctx: CGContext) {
        let ink = ScorePalette.ink
        let head = CGPoint(x: x + 0.6 * sp, y: y)
        ScoreGlyphs.drawHead(.normal, hollow: false, whole: false, centre: head, sp: sp * 0.8, colour: ink, context: ctx)
        ctx.fill(CGRect(x: head.x + 0.42 * sp, y: y - 2.6 * sp, width: max(1, 0.1 * sp), height: 2.6 * sp), ink)

        let font = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.4 * sp, nil)
        TimelineText.draw("= \(Int(document.bpm.rounded()))", font: font, colour: ink,
                          in: CGRect(x: head.x + 1.2 * sp, y: y - 1.5 * sp, width: 10 * sp, height: 2 * sp),
                          anchor: .centredLeft, context: ctx)
    }
}

/// The score's colours, as `CGColor`s.
enum ScorePalette {
    static let paper = TimelinePalette.cg(Theme.bgRoot)
    static let ink = TimelinePalette.cg(Theme.textBright)
    static let line = TimelinePalette.cg(Theme.textScale)
    static let faint = TimelinePalette.cg(Theme.textFaint)
    static let cursor = TimelinePalette.cg(Theme.accent)
}
