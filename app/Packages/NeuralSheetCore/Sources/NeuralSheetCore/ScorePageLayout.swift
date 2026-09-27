import Foundation

/// The score on pages (arrangement design §3.5): the system layout at the page's content width,
/// the systems dealt onto pages by height, never split; page 1 keeps room for the header, every
/// page for the footer.
public struct ScorePageLayout: Sendable {
    public struct Page: Sendable {
        public var index: Int
        /// Origin zero, the page's size in points.
        public var frame: CGRect
        /// `PageSize.headerHeight` on the first page, 0 after.
        public var headerHeight: CGFloat
        /// In page coordinates.
        public var systems: [ScoreSystemLayout.System]
    }

    /// A staff space on a page: printed music is set smaller than the screen's 8.
    public static let pageStaffSpace: CGFloat = 7
    /// Room under the last system for the copyright line and the page number.
    public static let footerHeight: CGFloat = 24

    public let pageSize: PageSize
    public let sp: CGFloat
    public let systems: ScoreSystemLayout
    public var pages: [Page] = []

    public init(document: ScoreDocument, arrangement: ScoreArrangement, pageSize: PageSize, sp: CGFloat = ScorePageLayout.pageStaffSpace) {
        self.pageSize = pageSize
        self.sp = sp

        let size = pageSize.points
        let contentWidth = size.width - 2 * PageSize.margin
        // The system layout lays out from its own left margin; shift so its left edge lands on
        // the page margin.
        systems = ScoreSystemLayout(document: document, arrangement: arrangement, width: contentWidth + (ScoreSystemLayout.leftMargin + ScoreSystemLayout.rightMargin) * sp, sp: sp)

        let dx = PageSize.margin - ScoreSystemLayout.leftMargin * sp
        var current = Page(index: 0, frame: CGRect(origin: .zero, size: size), headerHeight: PageSize.headerHeight, systems: [])
        var y = PageSize.margin + PageSize.headerHeight
        let bottom = size.height - PageSize.margin - ScorePageLayout.footerHeight

        for system in systems.systems {
            let height = system.frame.height + ScoreSystemLayout.systemGap * sp

            if !current.systems.isEmpty, y + system.frame.height > bottom {
                pages.append(current)
                current = Page(index: pages.count, frame: CGRect(origin: .zero, size: size), headerHeight: 0, systems: [])
                y = PageSize.margin
            }

            var placed = system.offset(by: y - system.frame.minY)
            placed.frame.origin.x += dx
            placed.measures = placed.measures.map { box in
                var box = box
                box.x += dx
                box.contentX += dx
                box.onsets = box.onsets.map { (units: $0.units, x: $0.x + dx) }
                return box
            }
            current.systems.append(placed)
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
