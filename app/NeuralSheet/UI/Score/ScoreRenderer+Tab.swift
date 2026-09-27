import AppKit
import CoreText
import NeuralSheetCore

extension ScoreRenderer {
    /// Fret numbers on the strings' lines, stems and flags below, ties as arcs under the numbers
    /// (arrangement design §4). Every number is recorded in `hits` for the selection.
    func drawTabMusic(_ tab: ScoreTabStaff, part: ScorePart, row: ScoreSystemLayout.StaffRow,
                      system: ScoreSystemLayout.System, in ctx: CGContext, hits: inout [TabHit]) {
        let lineGap = ScoreSystemLayout.tabLineGap * sp
        let font = CTFontCreateWithName(Fonts.monoName(500) as CFString, 1.35 * sp, nil)

        for (boxIndex, box) in system.measures.enumerated() where box.index < tab.measures.count {
            let measure = tab.measures[box.index]

            for (pieceIndex, piece) in measure.pieces.enumerated() {
                let x = piece.isWholeMeasureRest ? (box.contentX + box.endX) / 2 : box.x(forUnits: Double(piece.startUnits))

                if piece.isRest {
                    // A tab rest: the notation's rest glyph, small, centred on the tab.
                    ScoreGlyphs.drawRest(type: piece.type, dots: piece.dots, x: x, bottomLineY: row.bottomLineY - row.height / 2 + 2 * sp * 0.7,
                                         sp: sp * 0.7, colour: style.line, context: ctx)
                    continue
                }

                for note in piece.notes {
                    guard let placement = note.placement else { continue }

                    let y = row.bottomLineY - CGFloat(placement.string) * lineGap
                    let text = "\(placement.fret)"
                    let width = TimelineText.width(text, font: font) + 0.4 * sp
                    let frame = CGRect(x: x - width / 2, y: y - 0.75 * sp, width: width, height: 1.5 * sp)

                    // A box in the paper colour so the number covers the line.
                    ctx.setFillColor(style.paper)
                    ctx.fill(frame.insetBy(dx: 0, dy: 0.15 * sp))

                    let colour = placement.isPlayable ? style.ink : style.unplayable
                    TimelineText.draw(text, font: font, colour: colour, in: frame, anchor: .centred, context: ctx)

                    if let id = note.id {
                        hits.append(TabHit(program: part.program, id: id, frame: frame, string: placement.string))
                    }

                    if note.tiedTo {
                        let next = nextPiece(after: pieceIndex, in: measure, box: box, boxIndex: boxIndex, system: system, measures: tab.measures)
                        let continues = next?.piece.notes.contains { $0.pitch == note.pitch } == true
                        let toX = (continues ? next?.x : nil) ?? (box.endX - 0.3 * sp)

                        ScoreGlyphs.drawTie(from: CGPoint(x: x + width / 2, y: y + 0.6 * sp), to: CGPoint(x: toX - width / 2, y: y + 0.6 * sp),
                                            below: true, sp: sp, colour: colour, context: ctx)
                    }
                }

                // Rhythm under the tab: a stem from just below the bottom line, flags off it.
                guard piece.hasStem else { continue }

                let stemWidth = max(pixel, 0.13 * sp)
                let top = row.bottomLineY + 0.6 * sp
                let bottom = top + 2.6 * sp
                ctx.setFillColor(style.ink)
                ctx.fill(CGRect(x: x - stemWidth / 2, y: top, width: stemWidth, height: bottom - top))
                ScoreGlyphs.drawFlags(count: piece.flags, stemEnd: CGPoint(x: x + stemWidth / 2, y: bottom), stemUp: false, sp: sp,
                                      colour: style.ink, context: ctx)

                for dot in 0..<piece.dots {
                    ctx.fillEllipse(in: CGRect(x: x + (0.6 + CGFloat(dot) * 0.5) * sp, y: bottom - 0.4 * sp, width: 0.35 * sp, height: 0.35 * sp))
                }
            }
        }
    }
}
