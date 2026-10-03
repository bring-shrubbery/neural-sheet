import CoreGraphics
import CoreText
import NeuralSheetCore

/// The score's words (markers and lyrics design §2): the section markers as boxed rehearsal
/// marks over the top staff, and each part's lyric line under its bottom staff, syllables
/// centred on their heads, a hyphen between the syllables of a word and an extender under a
/// held syllable. The Score tab and the PDF both draw through here.
extension ScoreRenderer {
    var rehearsalFont: CTFont { CTFontCreateWithName(Fonts.sansName(700) as CFString, 1.6 * sp, nil) }
    var lyricFont: CTFont { CTFontCreateWithName(Fonts.sansName(400) as CFString, 1.5 * sp, nil) }

    // MARK: - Rehearsal marks

    /// Each mark of the system's measures in a box: at the system's left edge when its measure
    /// opens the system, else from the bar line. Its bottom sits clear of the measure number and
    /// the tempo mark, and above the chord symbols' line where a symbol in the system stands
    /// taller than that.
    func drawRehearsalMarks(_ system: ScoreSystemLayout.System, in ctx: CGContext) {
        guard !document.rehearsalMarks.isEmpty, let top = system.rows.first, let first = system.measures.first else { return }

        let font = rehearsalFont
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let pad = 0.45 * sp
        let chordTop = chordHits(system).map(\.frame.minY).min() ?? .infinity
        let bottom = min(top.topLineY - 4.4 * sp, chordTop - 0.6 * sp)
        let height = ascent + descent + 2 * pad

        for box in system.measures {
            guard let mark = document.rehearsalMarks.first(where: { $0.measure == box.index }) else { continue }

            let x = box.index == first.index ? system.frame.minX : box.x
            let width = TimelineText.width(mark.text, font: font) + 2 * pad
            let frame = CGRect(x: x, y: bottom - height, width: width, height: height)

            ctx.setFillColor(style.paper)
            ctx.fill(frame)
            ctx.setStrokeColor(style.ink)
            ctx.setLineWidth(max(pixel, 0.12 * sp))
            ctx.stroke(frame)
            TimelineText.draw(mark.text, font: font, colour: style.ink, in: frame, anchor: .centred, context: ctx)
        }
    }

    // MARK: - Lyrics

    /// One onset of a part in the system: where its heads stand and the syllable on it, if any.
    private struct LyricOnset {
        var x: CGFloat
        var lyric: Lyric?
    }

    /// The lyric line under `row`, the bottom staff of a part with words: the part's onsets
    /// across all its staves, left to right, and the words on them.
    func drawLyrics(_ system: ScoreSystemLayout.System, row: ScoreSystemLayout.StaffRow, in ctx: CGContext) {
        let part = document.parts[row.partIndex]
        let onsets = lyricOnsets(part, system: system)

        guard onsets.contains(where: { $0.lyric != nil }) else { return }

        let font = lyricFont
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baseline = lyricBaseline(part, row: row, system: system)
        let hyphenWidth = TimelineText.width("-", font: font)
        let rule = max(pixel, 0.1 * sp)
        let words = onsets.indices.filter { onsets[$0].lyric != nil }
        var previousEnd = -CGFloat.infinity

        for (order, index) in words.enumerated() {
            guard let lyric = onsets[index].lyric else { continue }

            let width = TimelineText.width(lyric.text, font: font)
            // Centred on the head; pushed right of the syllable before rather than over it.
            let start = max(onsets[index].x - width / 2, previousEnd + 0.4 * sp)
            let end = start + width
            let frame = CGRect(x: start, y: baseline - ascent, width: width, height: ascent + descent)

            TimelineText.draw(lyric.text, font: font, colour: style.ink, in: frame, anchor: .topLeft, context: ctx)
            previousEnd = end

            let next = order + 1 < words.count ? words[order + 1] : nil

            if lyric.syllabic.continues {
                // Between this syllable and the next; with the word running on into the next
                // system, just after this one.
                var centre = end + 0.8 * sp

                if let next, let following = onsets[next].lyric {
                    let nextStart = max(onsets[next].x - TimelineText.width(following.text, font: font) / 2, end + 0.4 * sp)
                    centre = (end + nextStart) / 2
                }

                TimelineText.draw("-", font: font, colour: style.ink,
                                  in: CGRect(x: centre - hyphenWidth / 2, y: baseline - ascent, width: hyphenWidth, height: ascent + descent),
                                  anchor: .topLeft, context: ctx)
            }

            if lyric.extends {
                // To the end of the last head the syllable is held over: the onset before the
                // next syllable, or the system's last.
                let last = next.map { onsets[$0 - 1].x } ?? onsets[onsets.count - 1].x
                let lineEnd = last + ScoreGlyphs.headWidth * sp / 2

                if lineEnd > end + 0.5 * sp {
                    ctx.fill(CGRect(x: end + 0.2 * sp, y: baseline - rule / 2, width: lineEnd - end - 0.2 * sp, height: rule), style.ink)
                }
            }
        }
    }

    /// Every piece with notes on any of the part's staves, by x; one onset per x, the one with
    /// a syllable winning, and per piece the syllable of its highest note that has one.
    private func lyricOnsets(_ part: ScorePart, system: ScoreSystemLayout.System) -> [LyricOnset] {
        var byX: [CGFloat: LyricOnset] = [:]

        for box in system.measures {
            for staff in part.staves where box.index < staff.measures.count {
                for piece in staff.measures[box.index].pieces where !piece.isRest {
                    let x = box.x(forUnits: Double(piece.startUnits))
                    let lyric = piece.lyricNoteIndex.flatMap { piece.notes[$0].lyric }

                    if byX[x]?.lyric == nil {
                        byX[x] = LyricOnset(x: x, lyric: lyric)
                    }
                }
            }
        }

        return byX.values.sorted { $0.x < $1.x }
    }

    /// Under the bottom staff, clear of a stem hanging down from it, and lower still under a head
    /// on ledger lines below it, so the words never run into the music.
    private func lyricBaseline(_ part: ScorePart, row: ScoreSystemLayout.StaffRow, system: ScoreSystemLayout.System) -> CGFloat {
        var lowest = row.bottomLineY

        if case let .staff(index, _) = row.kind, index < part.staves.count {
            for box in system.measures where box.index < part.staves[index].measures.count {
                for piece in part.staves[index].measures[box.index].pieces {
                    guard let low = piece.notes.first else { continue }

                    lowest = max(lowest, row.bottomLineY - CGFloat(low.step) * sp / 2)
                }
            }
        }

        return max(row.bottomLineY + 4.6 * sp, lowest + 2.6 * sp)
    }
}
