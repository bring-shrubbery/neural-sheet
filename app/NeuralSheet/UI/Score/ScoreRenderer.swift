import AppKit
import CoreText
import NeuralSheetCore

/// A tab note as drawn, for selection and the string card.
struct TabHit: Equatable {
    var program: Int
    var id: NoteID
    var frame: CGRect
    var string: Int
}

/// Draws a laid-out score into any `CGContext` (arrangement design §4): the view and the PDF
/// export share it. Staves, bar lines, clefs, signatures, part names, measure numbers and the
/// tempo here; chords in `+Chords`, tab staves in `+Tab`, the page's header and footer in `+Page`.
struct ScoreRenderer {
    let document: ScoreDocument
    let arrangement: ScoreArrangement
    let sp: CGFloat

    var pixel: CGFloat { max(1, (sp / 8).rounded()) }

    func drawSystem(_ system: ScoreSystemLayout.System, in ctx: CGContext, hits: inout [TabHit]) {
        drawStaffLines(system, in: ctx)
        drawBarLines(system, in: ctx)
        drawPrefixes(system, in: ctx)
        drawNumbersAndTempo(system, in: ctx)

        for row in system.rows {
            let part = document.parts[row.partIndex]

            switch row.kind {
            case let .staff(index, _):
                drawStaffMusic(part.staves[index], row: row, system: system, in: ctx)
            case .tab:
                if let tab = part.tab {
                    drawTabMusic(tab, part: part, row: row, system: system, in: ctx, hits: &hits)
                }
            }
        }
    }

    // MARK: - The frame

    /// Five lines for a staff, one per string for a tab, and the left edge joining every row.
    private func drawStaffLines(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        let line = ScorePalette.line

        for row in system.rows {
            for y in lineYs(of: row) {
                ctx.fill(CGRect(x: system.frame.minX, y: y - pixel / 2, width: system.frame.width, height: pixel), line)
            }
        }

        ctx.fill(CGRect(x: system.frame.minX, y: system.staffTop, width: pixel, height: system.staffBottom - system.staffTop), line)
    }

    /// The y of each of the row's lines, the bottom one first.
    private func lineYs(of row: ScoreSystemLayout.StaffRow) -> [CGFloat] {
        switch row.kind {
        case .staff:
            return (0..<5).map { row.bottomLineY - CGFloat($0) * sp }
        case .tab:
            let strings = document.parts[row.partIndex].tab?.tuning.count ?? 0
            return (0..<max(1, strings)).map { row.bottomLineY - CGFloat($0) * ScoreSystemLayout.tabLineGap * sp }
        }
    }

    /// Bar lines over every row, the final one doubled.
    private func drawBarLines(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        let isFinalSystem = system.measures.last?.index == document.measureCount - 1

        for row in system.rows {
            let top = row.topLineY

            for (index, box) in system.measures.enumerated() where index > 0 {
                ctx.fill(CGRect(x: box.x - pixel / 2, y: top, width: pixel, height: row.height), ScorePalette.line)
            }

            ctx.fill(CGRect(x: system.frame.maxX - pixel, y: top, width: pixel, height: row.height),
                     isFinalSystem ? ScorePalette.ink : ScorePalette.line)

            if isFinalSystem {
                ctx.fill(CGRect(x: system.frame.maxX - 0.5 * sp - pixel, y: top, width: pixel, height: row.height), ScorePalette.ink)
            }
        }
    }

    /// Part names, clefs (the "TAB" mark on a tab), key signatures and, on the first system, the
    /// time signature.
    private func drawPrefixes(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        let ink = ScorePalette.ink
        let isFirst = system.showsTimeSignature
        let nameFont = TimelineFonts.meta(sp / 8)

        for row in system.rows {
            let part = document.parts[row.partIndex]
            let partRows = system.rows.filter { $0.partIndex == row.partIndex }

            if arrangement.sheet.showsPartNames, partRows.first == row, let last = partRows.last {
                let colour = TimelinePalette.cg(Instruments.info(forProgram: part.program).colour, alpha: 1)
                let label = isFirst ? part.name : part.abbreviation
                let centreY = (row.topLineY + last.bottomLineY) / 2
                TimelineText.draw(label, font: nameFont, colour: colour,
                                  in: CGRect(x: 0, y: centreY - sp, width: system.frame.minX - 0.6 * sp, height: 2 * sp),
                                  anchor: .centredRight, context: ctx)
            }

            guard let first = system.measures.first else { continue }

            var x = first.x + 0.4 * sp

            switch row.kind {
            case .tab:
                ScoreGlyphs.drawTabClef(x: x, topLineY: row.topLineY, bottomLineY: row.bottomLineY, sp: sp, colour: ink, context: ctx)

            case let .staff(_, clef):
                ScoreGlyphs.drawClef(clef, x: x, bottomLineY: row.bottomLineY, sp: sp, colour: ink, context: ctx)
                x += ScoreSystemLayout.clefWidth * sp

                if clef != .percussion {
                    let accidental: Accidental = part.writtenFifths > 0 ? .sharp : .flat
                    for position in clef.signaturePositions(fifths: part.writtenFifths) {
                        let y = row.bottomLineY - CGFloat(position) * sp / 2
                        ScoreGlyphs.drawAccidental(accidental, x: x, y: y, sp: sp, colour: ink, context: ctx)
                        x += ScoreSystemLayout.accidentalWidth * sp
                    }
                } else {
                    x += CGFloat(abs(part.writtenFifths)) * ScoreSystemLayout.accidentalWidth * sp
                }

                if isFirst {
                    drawTimeSignature(x: x + 0.3 * sp, bottomLineY: row.bottomLineY, colour: ink, in: ctx)
                }
            }
        }
    }

    /// The measure number above the top row at the system's start; the tempo on the first system.
    private func drawNumbersAndTempo(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        guard let first = system.measures.first, let topRow = system.rows.first else { return }

        let y = topRow.topLineY

        if arrangement.sheet.showsMeasureNumbers {
            let numberFont = TimelineFonts.scaleLabel(sp / 8)
            TimelineText.draw("\(first.index + 1)", font: numberFont, colour: ScorePalette.faint,
                              in: CGRect(x: first.x, y: y - 2.6 * sp, width: 6 * sp, height: 1.6 * sp),
                              anchor: .centredLeft, context: ctx)
        }

        if system.showsTimeSignature, arrangement.sheet.showsTempo {
            drawTempo(x: first.contentX, y: y - 3.2 * sp, in: ctx)
        }
    }

    // MARK: - The music

    /// The staff's pieces over the system's measures: rests, chords, and ties to whatever comes
    /// next at the same pitch.
    private func drawStaffMusic(_ staff: ScoreStaff, row: ScoreSystemLayout.StaffRow, system: ScoreSystemLayout.System, in ctx: CGContext) {
        let ink = ScorePalette.ink

        for (boxIndex, box) in system.measures.enumerated() where box.index < staff.measures.count {
            let measure = staff.measures[box.index]

            for (pieceIndex, piece) in measure.pieces.enumerated() {
                let x = piece.isWholeMeasureRest ? (box.contentX + box.endX) / 2 : box.x(forUnits: Double(piece.startUnits))

                if piece.isRest {
                    ScoreGlyphs.drawRest(type: piece.type, dots: piece.dots, x: x, bottomLineY: row.bottomLineY, sp: sp, colour: ink, context: ctx)
                    continue
                }

                drawChord(piece, x: x, row: row, in: ctx)

                let tied = piece.notes.filter(\.tiedTo)
                guard !tied.isEmpty else { continue }

                let next = nextPiece(after: pieceIndex, in: measure, box: box, boxIndex: boxIndex, system: system, measures: staff.measures)
                let stemUp = ScoreRenderer.stemUp(piece)

                for note in tied {
                    let y = row.bottomLineY - CGFloat(note.step) * sp / 2
                    let from = CGPoint(x: x + 0.7 * sp, y: y + (stemUp ? 0.55 : -0.55) * sp)
                    let toX = (next?.piece.notes.contains { $0.pitch == note.pitch } == true ? next?.x : nil) ?? (box.endX - 0.3 * sp)
                    let to = CGPoint(x: toX - 0.7 * sp, y: from.y)
                    ScoreGlyphs.drawTie(from: from, to: to, below: stemUp, sp: sp, colour: ink, context: ctx)
                }
            }
        }
    }

    /// The piece after `pieceIndex` of `measure`, in the same measure or at the start of the
    /// system's next one, with its x; nil at the system's end.
    func nextPiece(after pieceIndex: Int, in measure: ScoreMeasure, box: ScoreSystemLayout.MeasureBox, boxIndex: Int,
                   system: ScoreSystemLayout.System, measures: [ScoreMeasure]) -> (piece: ScorePiece, x: CGFloat)? {
        if pieceIndex + 1 < measure.pieces.count {
            let piece = measure.pieces[pieceIndex + 1]
            return (piece, box.x(forUnits: Double(piece.startUnits)))
        }

        guard boxIndex + 1 < system.measures.count else { return nil }

        let nextBox = system.measures[boxIndex + 1]

        guard nextBox.index < measures.count, let piece = measures[nextBox.index].pieces.first else { return nil }

        return (piece, nextBox.x(forUnits: Double(piece.startUnits)))
    }
}

/// The score's colours, as `CGColor`s.
enum ScorePalette {
    static let paper = TimelinePalette.cg(Theme.bgRoot)
    static let ink = TimelinePalette.cg(Theme.textBright)
    static let line = TimelinePalette.cg(Theme.textScale)
    static let faint = TimelinePalette.cg(Theme.textFaint)
    static let cursor = TimelinePalette.cg(Theme.accent)
    /// A tab fret no string can hold.
    static let unplayable = TimelinePalette.cg(Theme.warn)
    static let selection = TimelinePalette.cg(Theme.accent, alpha: 0.35)
    static let selectionEdge = TimelinePalette.cg(Theme.accent)
}
