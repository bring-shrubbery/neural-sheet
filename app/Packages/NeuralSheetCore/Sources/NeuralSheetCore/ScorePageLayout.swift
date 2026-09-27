import Foundation

/// The score on pages (arrangement design §3.5): the system layout at the page's content width,
/// the systems dealt onto pages by height, never split; page 1 keeps room for the header, every
/// page for the footer, and two staff spaces of slack keep a clef, a ledger line or a stem out of
/// either band.
///
/// `scale` multiplies the page size, the margins, the header and the footer, so the pages come
/// out in the same scaled points as `sp`, which the caller passes already scaled: the view
/// draws at the interface scale, the PDF at 1.
public struct ScorePageLayout: Sendable {
    public struct Page: Sendable {
        public var index: Int
        /// Origin zero, the page's size in points (scaled).
        public var frame: CGRect
        /// `PageSize.headerHeight` (scaled) on the first page, 0 after.
        public var headerHeight: CGFloat
        /// In page coordinates.
        public var systems: [ScoreSystemLayout.System]
    }

    /// A staff space on a page: printed music is set smaller than the screen's 8.
    public static let pageStaffSpace: CGFloat = 7
    /// Room under the last system for the copyright line and the page number.
    public static let footerHeight: CGFloat = 24
    /// Between a system and the header or footer band, in staff spaces: overhanging ink.
    public static let bandSlack: CGFloat = 2

    public let pageSize: PageSize
    public let sp: CGFloat
    public let scale: CGFloat
    public let systems: ScoreSystemLayout
    public var pages: [Page] = []

    public init(document: ScoreDocument, arrangement: ScoreArrangement, pageSize: PageSize,
                sp: CGFloat = ScorePageLayout.pageStaffSpace, scale: CGFloat = 1) {
        self.pageSize = pageSize
        self.sp = sp
        self.scale = scale

        let size = CGSize(width: pageSize.points.width * scale, height: pageSize.points.height * scale)
        let margin = PageSize.margin * scale
        let headerHeight = PageSize.headerHeight * scale
        let footerHeight = ScorePageLayout.footerHeight * scale
        let slack = ScorePageLayout.bandSlack * sp
        let contentWidth = size.width - 2 * margin
        // The system layout lays out from its own left margin; shift so its left edge lands on
        // the page margin.
        systems = ScoreSystemLayout(document: document, arrangement: arrangement, width: contentWidth + (ScoreSystemLayout.leftMargin + ScoreSystemLayout.rightMargin) * sp, sp: sp)

        let dx = margin - ScoreSystemLayout.leftMargin * sp
        var current = Page(index: 0, frame: CGRect(origin: .zero, size: size), headerHeight: headerHeight, systems: [])
        var y = margin + headerHeight + slack
        let bottom = size.height - margin - footerHeight

        for system in systems.systems {
            let height = system.frame.height + ScoreSystemLayout.systemGap * sp

            if !current.systems.isEmpty, y + system.frame.height + slack > bottom {
                pages.append(current)
                current = Page(index: pages.count, frame: CGRect(origin: .zero, size: size), headerHeight: 0, systems: [])
                y = margin + slack
            }

            current.systems.append(system.offset(by: y - system.frame.minY).offsetX(by: dx))
            y += height
        }

        pages.append(current)
    }

    /// The page and system holding measure `index`.
    public func box(forMeasure index: Int) -> (page: Page, system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        for page in pages {
            for system in page.systems {
                if let box = system.measures.first(where: { $0.index == index }) {
                    return (page, system, box)
                }
            }
        }

        return nil
    }
}
