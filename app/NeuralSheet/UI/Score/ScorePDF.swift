import AppKit
import NeuralSheetCore

/// The score's pages as a PDF (arrangement design §5): one PDF page per laid-out page, the
/// renderer drawing into a flipped PDF context exactly as it draws into the view.
enum ScorePDF {
    static func data(document: ScoreDocument, arrangement: ScoreArrangement, takeName: String?) -> Data? {
        var paged = arrangement
        paged.layout = .pages

        let layout = ScorePageLayout(document: document, arrangement: paged, pageSize: paged.pageSize, sp: ScorePageLayout.pageStaffSpace)
        let renderer = ScoreRenderer(document: document, arrangement: paged, sp: layout.sp, style: .print)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }

        var mediaBox = CGRect(origin: .zero, size: paged.pageSize.points)

        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for page in layout.pages {
            ctx.beginPDFPage(nil)
            // The renderer draws y-down; PDF is y-up. `TimelineText.draw` sets a text matrix
            // for a flipped context and `ScoreGlyphs.drawGlyph` maps through the CTM, so both
            // come out upright here.
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)

            var hits: [TabHit] = []
            var names: [NameHit] = []
            renderer.drawPage(page, frame: page.frame, systems: page.systems, takeName: takeName, scale: 1, in: ctx, hits: &hits, names: &names)

            ctx.endPDFPage()
        }

        ctx.closePDF()

        return data as Data
    }
}
