import AppKit
import CoreText
import NeuralSheetCore

extension ScoreRenderer {
    /// A page (arrangement design §4): the sheet, the header on page 1, its systems, the footer.
    /// `frame` is the page in the context's coordinates and `systems` are already there; `scale`
    /// is what the page layout was built with, for the margins.
    func drawPage(_ page: ScorePageLayout.Page, frame: CGRect, systems: [ScoreSystemLayout.System], takeName: String?,
                  scale: CGFloat, in ctx: CGContext, hits: inout [TabHit], names: inout [NameHit]) {
        let margin = PageSize.margin * scale

        ctx.setFillColor(style.paper)
        ctx.fill(frame)

        if page.index == 0 {
            drawHeader(in: CGRect(x: frame.minX + margin, y: frame.minY + margin,
                                  width: frame.width - 2 * margin, height: PageSize.headerHeight * scale),
                       takeName: takeName, in: ctx)
        }

        for system in systems {
            drawSystem(system, in: ctx, hits: &hits, names: &names)
        }

        let footerHeight = ScorePageLayout.footerHeight * scale
        drawFooter(pageIndex: page.index,
                   in: CGRect(x: frame.minX + margin, y: frame.maxY - margin - footerHeight,
                              width: frame.width - 2 * margin, height: footerHeight),
                   in: ctx)
    }

    /// The title centred in the sans at 3 sp, the subtitle below at 1.8 sp, the composer
    /// right-aligned and the arranger under it at 1.6 sp (arrangement design §4).
    private func drawHeader(in rect: CGRect, takeName: String?, in ctx: CGContext) {
        let sheet = arrangement.sheet
        let title = CTFontCreateWithName(Fonts.sansName(600) as CFString, 3 * sp, nil)
        let subtitle = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.8 * sp, nil)
        let small = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.6 * sp, nil)

        TimelineText.draw(sheet.resolvedTitle(takeName: takeName), font: title, colour: style.ink,
                          in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3.6 * sp), anchor: .centred, context: ctx)

        if !sheet.subtitle.isEmpty {
            TimelineText.draw(sheet.subtitle, font: subtitle, colour: style.ink,
                              in: CGRect(x: rect.minX, y: rect.minY + 3.6 * sp, width: rect.width, height: 2.2 * sp),
                              anchor: .centred, context: ctx)
        }

        if !sheet.composer.isEmpty {
            TimelineText.draw(sheet.composer, font: small, colour: style.ink,
                              in: CGRect(x: rect.minX, y: rect.maxY - 4 * sp, width: rect.width, height: 2 * sp),
                              anchor: .centredRight, context: ctx)
        }

        if !sheet.arranger.isEmpty {
            TimelineText.draw("arr. " + sheet.arranger, font: small, colour: style.ink,
                              in: CGRect(x: rect.minX, y: rect.maxY - 2 * sp, width: rect.width, height: 2 * sp),
                              anchor: .centredRight, context: ctx)
        }
    }

    /// The copyright centred at 1.2 sp with the page number at the outer edge: right on odd
    /// pages, left on even (arrangement design §4).
    private func drawFooter(pageIndex: Int, in rect: CGRect, in ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(400) as CFString, 1.2 * sp, nil)

        if !arrangement.sheet.copyright.isEmpty {
            TimelineText.draw(arrangement.sheet.copyright, font: font, colour: style.faint, in: rect, anchor: .centred, context: ctx)
        }

        TimelineText.draw("\(pageIndex + 1)", font: font, colour: style.faint, in: rect,
                          anchor: pageIndex % 2 == 0 ? .centredRight : .centredLeft, context: ctx)
    }
}
