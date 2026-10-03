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

/// A part's name as drawn, for the click that opens its display card.
struct NameHit: Equatable {
    var program: Int
    var frame: CGRect
}

/// Draws a laid-out score into any `CGContext` (arrangement design §4): the view and the PDF
/// export share it. Staves, bar lines, clefs, signatures, part names, measure numbers and the
/// tempo here; chords in `+Chords`, chord symbols in `+Harmony`, rehearsal marks and lyrics in
/// `+Text`, tab staves in `+Tab`, the page's header and footer in `+Page`.
struct ScoreRenderer {
    let document: ScoreDocument
    let arrangement: ScoreArrangement
    let sp: CGFloat
    let style: Style

    init(document: ScoreDocument, arrangement: ScoreArrangement, sp: CGFloat, style: Style = .screen) {
        self.document = document
        self.arrangement = arrangement
        self.sp = sp
        self.style = style
    }

    var pixel: CGFloat { max(1, (sp / 8).rounded()) }

    /// Every tab number goes into `hits` and every part name into `names`, for the clicks.
    /// `leftEdge` is the paper's left edge in the context: the page's when the system is on a
    /// page, 0 in the continuous column. The part names have the room between it and the system.
    func drawSystem(_ system: ScoreSystemLayout.System, leftEdge: CGFloat = 0, in ctx: CGContext,
                    hits: inout [TabHit], names: inout [NameHit]) {
        drawStaffLines(system, in: ctx)
        drawBarLines(system, in: ctx)
        drawPrefixes(system, leftEdge: leftEdge, in: ctx, names: &names)
        drawNumbersAndTempo(system, in: ctx)
        drawChordSymbols(system, in: ctx)
        drawRehearsalMarks(system, in: ctx)

        for row in system.rows {
            let part = document.parts[row.partIndex]

            switch row.kind {
            case let .staff(index, _):
                drawStaffMusic(part.staves[index], row: row, system: system, in: ctx)

                if row.lyricsBelow {
                    drawLyrics(system, row: row, in: ctx)
                }
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
        let line = style.line

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
                ctx.fill(CGRect(x: box.x - pixel / 2, y: top, width: pixel, height: row.height), style.line)
            }

            ctx.fill(CGRect(x: system.frame.maxX - pixel, y: top, width: pixel, height: row.height),
                     isFinalSystem ? style.ink : style.line)

            if isFinalSystem {
                ctx.fill(CGRect(x: system.frame.maxX - 0.5 * sp - pixel, y: top, width: pixel, height: row.height), style.ink)
            }
        }
    }

    /// Part names, clefs (the "TAB" mark on a tab), key signatures and the time signature when
    /// the system opens with one (the first, or a meter change; tempo map design §2). The full name goes on the first system and the abbreviation on the rest,
    /// but a name wider than the margin's room ("Acoustic Guitar") is abbreviated on the first
    /// system too rather than clipped. The room is measured from `leftEdge`, the paper's edge,
    /// so a page centred on screen gives a name the page margin, as the PDF does, and not the
    /// surround beside it.
    private func drawPrefixes(_ system: ScoreSystemLayout.System, leftEdge: CGFloat, in ctx: CGContext, names: inout [NameHit]) {
        let ink = style.ink
        let isFirst = system.isFirst
        let nameFont = TimelineFonts.meta(sp / 8)

        for row in system.rows {
            let part = document.parts[row.partIndex]
            let partRows = system.rows.filter { $0.partIndex == row.partIndex }

            if partRows.first == row, let last = partRows.last {
                let room = system.frame.minX - leftEdge - 0.6 * sp
                let centreY = (row.topLineY + last.bottomLineY) / 2
                // With the names off, the margin beside the part's first row stays the click
                // that opens its card, since the name is the only way to it: the hit region is
                // the whole room the name would have had.
                var hitFrame = CGRect(x: leftEdge, y: centreY - sp, width: room, height: 2 * sp)

                if arrangement.sheet.showsPartNames {
                    let colour = TimelinePalette.cg(Instruments.info(forProgram: part.program).colour, alpha: 1)
                    var label = isFirst ? part.name : part.abbreviation
                    var width = TimelineText.width(label, font: nameFont)

                    if width > room, label != part.abbreviation {
                        label = part.abbreviation
                        width = TimelineText.width(label, font: nameFont)
                    }

                    TimelineText.draw(label, font: nameFont, colour: colour, in: hitFrame, anchor: .centredRight, context: ctx)
                    hitFrame = CGRect(x: leftEdge + max(0, room - width), y: centreY - sp, width: min(width, room), height: 2 * sp)
                }

                names.append(NameHit(program: part.program, frame: hitFrame))
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

                if system.showsTimeSignature, first.index < document.bars.count {
                    drawTimeSignature(document.bars[first.index].timeSignature, x: x + 0.3 * sp, bottomLineY: row.bottomLineY,
                                      colour: ink, in: ctx)
                }
            }
        }
    }

    /// The measure number above the top row at the system's start; a tempo mark over each
    /// measure that changes the tempo, the first included, and a meter change inside the system
    /// on each staff before its measure's music (tempo map design §2).
    private func drawNumbersAndTempo(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        guard let first = system.measures.first, let topRow = system.rows.first else { return }

        let y = topRow.topLineY

        if arrangement.sheet.showsMeasureNumbers {
            let numberFont = TimelineFonts.scaleLabel(sp / 8)
            TimelineText.draw("\(first.index + 1)", font: numberFont, colour: style.faint,
                              in: CGRect(x: first.x, y: y - 2.6 * sp, width: 6 * sp, height: 1.6 * sp),
                              anchor: .centredLeft, context: ctx)
        }

        for box in system.measures where box.index < document.bars.count {
            let bar = document.bars[box.index]

            if bar.showsTempo, arrangement.sheet.showsTempo {
                drawTempo(bar, x: box.contentX, y: y - 3.2 * sp, in: ctx)
            }

            if let meterX = box.timeSignatureX {
                for row in system.rows {
                    if case .staff = row.kind {
                        drawTimeSignature(bar.timeSignature, x: meterX, bottomLineY: row.bottomLineY, colour: style.ink, in: ctx)
                    }
                }
            }
        }
    }

    // MARK: - The music

    /// The staff's pieces over the system's measures: rests, chords, and ties to whatever comes
    /// next at the same pitch.
    private func drawStaffMusic(_ staff: ScoreStaff, row: ScoreSystemLayout.StaffRow, system: ScoreSystemLayout.System, in ctx: CGContext) {
        let ink = style.ink

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

extension ScoreRenderer {
    /// The score's colours (arrangement design §4): the screen's, the theme's paper and ink, or
    /// the print's, black on white. The view draws its own surround, cursor and selection outline
    /// from `screen` too, so no colour is defined twice.
    struct Style {
        var paper: CGColor
        var ink: CGColor
        var line: CGColor
        var faint: CGColor
        /// A tab fret no string can hold.
        var unplayable: CGColor
        var cursor: CGColor
        var selectionEdge: CGColor
        /// The line around a page, so the sheet reads against the surround; nil draws none.
        var pageEdge: CGColor?

        static let screen = Style(paper: TimelinePalette.cg(Theme.bgRoot),
                                  ink: TimelinePalette.cg(Theme.textBright),
                                  line: TimelinePalette.cg(Theme.textScale),
                                  faint: TimelinePalette.cg(Theme.textFaint),
                                  unplayable: TimelinePalette.cg(Theme.warn),
                                  cursor: TimelinePalette.cg(Theme.accent),
                                  selectionEdge: TimelinePalette.cg(Theme.accent),
                                  pageEdge: TimelinePalette.cg(Theme.textScale))

        /// For paper: the unplayable warning and the accent stay the screen's; the page has no
        /// surround to read against, so no edge.
        static let print = Style(paper: CGColor(gray: 1, alpha: 1),
                                 ink: CGColor(gray: 0, alpha: 1),
                                 line: CGColor(gray: 0.45, alpha: 1),
                                 faint: CGColor(gray: 0.55, alpha: 1),
                                 unplayable: TimelinePalette.cg(Theme.warn),
                                 cursor: TimelinePalette.cg(Theme.accent),
                                 selectionEdge: TimelinePalette.cg(Theme.accent),
                                 pageEdge: nil)
    }
}
