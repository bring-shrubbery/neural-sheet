import CoreGraphics
import CoreText
import NeuralSheetCore

/// The marks a score is made of (score design §2): clefs and accidentals as Apple Symbols glyphs
/// fitted to the extents an engraver gives them, everything else as paths. All sizes in staff
/// spaces, so one `sp` scales the lot.
enum ScoreGlyphs {
    static let symbolFont = "Apple Symbols"

    /// A glyph from `font`, its ink fitted to `target`. Draws nothing when the font lacks it.
    static func drawGlyph(_ scalar: UInt32, font fontName: String = ScoreGlyphs.symbolFont, in target: CGRect,
                          colour: CGColor, context ctx: CGContext) {
        guard let unicode = UnicodeScalar(scalar) else { return }

        let utf16 = Array(String(unicode).utf16)
        let font = CTFontCreateWithName(fontName as CFString, 64, nil)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)

        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), let glyph = glyphs.first else { return }

        var glyphCopy = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyphCopy, &bounds, 1)

        guard bounds.width > 0, bounds.height > 0 else { return }

        ctx.saveGState()
        ctx.setFillColor(colour)
        // AppKit leaves a flipped text matrix in a flipped view's context; the glyph is placed
        // through the CTM alone here.
        ctx.textMatrix = .identity
        // The view is flipped; CoreText draws y-up. Map the glyph's ink box onto the target.
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: target.width / bounds.width, y: -target.height / bounds.height)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        var position = CGPoint.zero
        CTFontDrawGlyphs(font, &glyphCopy, &position, 1, ctx)
        ctx.restoreGState()
    }

    // MARK: - Clefs

    /// The treble clef about the G line (`gLineY`), the bass clef about the F line (`fLineY`),
    /// the C clef about the alto's middle line or the tenor's fourth, with SMuFL's extents; the
    /// octave clefs are their parents with a small 8 under the tail; the percussion clef is two
    /// thick bars about the middle line.
    static func drawClef(_ clef: Clef, x: CGFloat, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        switch clef {
        case .treble, .treble8vb:
            let gLineY = bottomLineY - 1 * sp
            let target = CGRect(x: x, y: gLineY - 4.392 * sp, width: 2.684 * sp, height: 7.024 * sp)
            drawGlyph(0x1D11E, in: target, colour: colour, context: ctx)
            if clef.isOctaveDown { drawOctaveMark(under: target, bottomLineY: bottomLineY, sp: sp, colour: colour, context: ctx) }

        case .bass, .bass8vb:
            let fLineY = bottomLineY - 3 * sp
            let target = CGRect(x: x, y: fLineY - 1.048 * sp, width: 2.736 * sp, height: 3.642 * sp)
            drawGlyph(0x1D122, in: target, colour: colour, context: ctx)
            if clef.isOctaveDown { drawOctaveMark(under: target, bottomLineY: bottomLineY, sp: sp, colour: colour, context: ctx) }

        case .alto, .tenor:
            let centreY = bottomLineY - (clef == .alto ? 2 : 3) * sp
            let target = CGRect(x: x, y: centreY - 2.024 * sp, width: 2.796 * sp, height: 4.048 * sp)
            drawGlyph(0x1D121, in: target, colour: colour, context: ctx)

        case .percussion:
            ctx.setFillColor(colour)
            let middle = bottomLineY - 2 * sp
            ctx.fill(CGRect(x: x + 0.5 * sp, y: middle - sp, width: 0.5 * sp, height: 2 * sp))
            ctx.fill(CGRect(x: x + 1.4 * sp, y: middle - sp, width: 0.5 * sp, height: 2 * sp))
        }
    }

    /// "TAB" stacked down the staff's height, in place of a clef.
    static func drawTabClef(x: CGFloat, topLineY: CGFloat, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(600) as CFString, 1.6 * sp, nil)
        let height = bottomLineY - topLineY
        for (index, letter) in ["T", "A", "B"].enumerated() {
            let y = topLineY + height * (CGFloat(index) + 0.5) / 3
            TimelineText.draw(letter, font: font, colour: colour, in: CGRect(x: x, y: y - sp, width: 2.4 * sp, height: 2 * sp), anchor: .centred, context: ctx)
        }
    }

    /// The 8 of an octave clef, centred under the clef's tail and clear of the bottom line (the
    /// bass clef's tail ends above it).
    private static func drawOctaveMark(under target: CGRect, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(600) as CFString, 1.4 * sp, nil)
        let top = max(target.maxY, bottomLineY + 0.5 * sp)
        let rect = CGRect(x: target.midX - 0.8 * sp, y: top, width: 1.6 * sp, height: 1.6 * sp)
        TimelineText.draw("8", font: font, colour: colour, in: rect, anchor: .centred, context: ctx)
    }

    // MARK: - Accidentals

    /// An accidental centred on the line or space at `y`: a sharp or a natural about it, a flat
    /// with its bulb on it and its stem above.
    static func drawAccidental(_ accidental: Accidental, x: CGFloat, y: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        switch accidental {
        case .sharp:
            drawGlyph(0x266F, in: CGRect(x: x, y: y - 1.4 * sp, width: 1.0 * sp, height: 2.8 * sp), colour: colour, context: ctx)
        case .natural:
            drawGlyph(0x266E, in: CGRect(x: x, y: y - 1.35 * sp, width: 0.85 * sp, height: 2.7 * sp), colour: colour, context: ctx)
        case .flat:
            drawGlyph(0x266D, in: CGRect(x: x, y: y - 1.8 * sp, width: 0.9 * sp, height: 2.5 * sp), colour: colour, context: ctx)
        }
    }

    // MARK: - Noteheads

    static let headWidth: CGFloat = 1.18
    static let headHeight: CGFloat = 0.86
    static let wholeHeadWidth: CGFloat = 1.5

    /// A notehead centred at `centre`.
    static func drawHead(_ head: ScoreNote.Head, hollow: Bool, whole: Bool, centre: CGPoint, sp: CGFloat, colour: CGColor,
                         context ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(colour)
        ctx.setStrokeColor(colour)

        switch head {
        case .normal:
            let width = (whole ? wholeHeadWidth : headWidth) * sp
            let height = headHeight * sp
            ctx.translateBy(x: centre.x, y: centre.y)
            if !whole { ctx.rotate(by: -0.35) }
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)

            if hollow {
                ctx.setLineWidth(max(1, 0.17 * sp))
                ctx.strokeEllipse(in: rect.insetBy(dx: 0.09 * sp, dy: 0.09 * sp))
            } else {
                ctx.fillEllipse(in: rect)
            }

        case .x:
            let r = 0.5 * sp
            ctx.setLineWidth(max(1, 0.16 * sp))
            ctx.move(to: CGPoint(x: centre.x - r, y: centre.y - r))
            ctx.addLine(to: CGPoint(x: centre.x + r, y: centre.y + r))
            ctx.move(to: CGPoint(x: centre.x - r, y: centre.y + r))
            ctx.addLine(to: CGPoint(x: centre.x + r, y: centre.y - r))
            ctx.strokePath()

        case .diamond:
            let r = 0.55 * sp
            ctx.move(to: CGPoint(x: centre.x, y: centre.y - r))
            ctx.addLine(to: CGPoint(x: centre.x + r, y: centre.y))
            ctx.addLine(to: CGPoint(x: centre.x, y: centre.y + r))
            ctx.addLine(to: CGPoint(x: centre.x - r, y: centre.y))
            ctx.closePath()
            if hollow {
                ctx.setLineWidth(max(1, 0.15 * sp))
                ctx.strokePath()
            } else {
                ctx.fillPath()
            }

        case .triangle:
            let r = 0.55 * sp
            ctx.move(to: CGPoint(x: centre.x, y: centre.y - r))
            ctx.addLine(to: CGPoint(x: centre.x + r, y: centre.y + r))
            ctx.addLine(to: CGPoint(x: centre.x - r, y: centre.y + r))
            ctx.closePath()
            ctx.fillPath()
        }

        ctx.restoreGState()
    }

    // MARK: - Flags

    /// `count` flags off a stem ending at `end`, curling toward the notehead (`down` when the stem
    /// points up, so the flags hang).
    static func drawFlags(count: Int, stemEnd end: CGPoint, stemUp: Bool, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        guard count > 0 else { return }

        let direction: CGFloat = stemUp ? 1 : -1
        ctx.setFillColor(colour)

        for index in 0..<count {
            let y = end.y + CGFloat(index) * 0.85 * sp * direction

            ctx.move(to: CGPoint(x: end.x, y: y))
            ctx.addCurve(to: CGPoint(x: end.x + 1.05 * sp, y: y + 1.9 * sp * direction),
                         control1: CGPoint(x: end.x + 0.15 * sp, y: y + 0.7 * sp * direction),
                         control2: CGPoint(x: end.x + 0.95 * sp, y: y + 1.05 * sp * direction))
            ctx.addCurve(to: CGPoint(x: end.x, y: y + 0.9 * sp * direction),
                         control1: CGPoint(x: end.x + 0.95 * sp, y: y + 1.35 * sp * direction),
                         control2: CGPoint(x: end.x + 0.45 * sp, y: y + 1.0 * sp * direction))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: - Rests

    /// A rest of `type` centred on `x`, on a staff whose bottom line is `bottomLineY`.
    static func drawRest(type: String, dots: Int, x: CGFloat, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(colour)
        ctx.setStrokeColor(colour)

        let middle = bottomLineY - 2 * sp

        switch type {
        case "whole":
            // Hangs from the fourth line.
            ctx.fill(CGRect(x: x - 0.65 * sp, y: middle - sp, width: 1.3 * sp, height: 0.5 * sp))
        case "half":
            // Sits on the middle line.
            ctx.fill(CGRect(x: x - 0.65 * sp, y: middle - 0.5 * sp, width: 1.3 * sp, height: 0.5 * sp))
        case "quarter":
            ctx.setLineWidth(max(1, 0.42 * sp))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: x - 0.25 * sp, y: middle - 1.5 * sp))
            ctx.addLine(to: CGPoint(x: x + 0.45 * sp, y: middle - 0.6 * sp))
            ctx.addLine(to: CGPoint(x: x - 0.15 * sp, y: middle + 0.2 * sp))
            ctx.addLine(to: CGPoint(x: x + 0.45 * sp, y: middle + 1.0 * sp))
            ctx.addQuadCurve(to: CGPoint(x: x - 0.1 * sp, y: middle + 1.5 * sp), control: CGPoint(x: x - 0.4 * sp, y: middle + 0.8 * sp))
            ctx.strokePath()
        default:
            // 8th, 16th, 32nd: a slanted stem with a hook per flag.
            let hooks = type == "eighth" ? 1 : type == "16th" ? 2 : 3
            let top = middle - 1.0 * sp
            let bottom = middle + CGFloat(hooks) * 0.6 * sp + 0.6 * sp
            ctx.setLineWidth(max(1, 0.16 * sp))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: x + 0.45 * sp, y: top))
            ctx.addLine(to: CGPoint(x: x - 0.35 * sp, y: bottom))
            ctx.strokePath()

            for hook in 0..<hooks {
                let hookY = top + CGFloat(hook) * sp
                let stemX = x + 0.45 * sp - (hookY - top) / (bottom - top) * 0.8 * sp
                ctx.move(to: CGPoint(x: stemX, y: hookY))
                ctx.addQuadCurve(to: CGPoint(x: x - 0.55 * sp, y: hookY + 0.05 * sp), control: CGPoint(x: x - 0.05 * sp, y: hookY + 0.6 * sp))
                ctx.strokePath()
                ctx.fillEllipse(in: CGRect(x: x - 0.85 * sp, y: hookY - 0.25 * sp, width: 0.6 * sp, height: 0.6 * sp))
            }
        }

        for dot in 0..<dots {
            let dotX = x + 1.0 * sp + CGFloat(dot) * 0.55 * sp
            ctx.fillEllipse(in: CGRect(x: dotX, y: middle - 0.5 * sp - 0.2 * sp, width: 0.4 * sp, height: 0.4 * sp))
        }

        ctx.restoreGState()
    }

    // MARK: - Ties

    /// An arc from `from` to `to`, bulging `below` or above by up to a space.
    static func drawTie(from: CGPoint, to: CGPoint, below: Bool, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        let span = max(to.x - from.x, sp)
        let bulge = min(1.0 * sp, span * 0.3) * (below ? 1 : -1)

        ctx.saveGState()
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(max(1, 0.14 * sp))
        ctx.move(to: from)
        ctx.addCurve(to: to,
                     control1: CGPoint(x: from.x + span * 0.3, y: from.y + bulge),
                     control2: CGPoint(x: to.x - span * 0.3, y: to.y + bulge))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
