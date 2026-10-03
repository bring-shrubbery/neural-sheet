import CoreGraphics
import NeuralSheetCore

/// The Score tab's geometry in view coordinates (arrangement design §6): the continuous system
/// layout at the screen's staff space, or the pages stacked down the view with a gap between,
/// each centred in the width. Both modes expose their systems flat, in order, so the cursor,
/// the click and the follow work the same way whichever is showing.
struct ScoreLayout {
    static let pageGap: CGFloat = 24
    /// Authored staff space; scaled by the view's scale.
    static let staffSpace: CGFloat = 8
    /// The grey behind the pages (arrangement design §6).
    static let surround = TimelinePalette.cg(Theme.bgPanel)

    let mode: ScoreLayoutMode
    let scale: CGFloat
    let sp: CGFloat
    let continuous: ScoreSystemLayout?
    let pages: ScorePageLayout?
    /// Each page's frame in view coordinates (pages mode; empty otherwise).
    let pageFrames: [CGRect]
    /// Each page's systems in view coordinates (pages mode; empty otherwise). Page by page these
    /// are `systems` in order, so a page's first system sits at the flat index of the systems
    /// before it.
    let pagesSystems: [[ScoreSystemLayout.System]]
    /// Every system in view coordinates, whichever mode.
    let systems: [ScoreSystemLayout.System]
    let totalHeight: CGFloat

    init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, scale: CGFloat) {
        mode = arrangement.layout
        self.scale = scale

        switch arrangement.layout {
        case .continuous:
            let layout = ScoreSystemLayout(document: document, arrangement: arrangement, width: width,
                                           sp: ScoreLayout.staffSpace * scale)
            sp = layout.sp
            continuous = layout
            pages = nil
            pageFrames = []
            pagesSystems = []
            systems = layout.systems
            totalHeight = layout.totalHeight

        case .pages:
            // The page layout takes the staff space already scaled and scales the sheet itself,
            // so its points are the view's.
            let layout = ScorePageLayout(document: document, arrangement: arrangement, pageSize: arrangement.pageSize,
                                         sp: ScorePageLayout.pageStaffSpace * scale, scale: scale)
            sp = layout.sp
            continuous = nil
            pages = layout

            var frames: [CGRect] = []
            var perPage: [[ScoreSystemLayout.System]] = []
            var y = ScoreLayout.pageGap

            for page in layout.pages {
                let frame = CGRect(origin: CGPoint(x: max(0, (width - page.frame.width) / 2), y: y), size: page.frame.size)
                frames.append(frame)
                perPage.append(page.systems.map { $0.offset(by: frame.minY).offsetX(by: frame.minX) })
                y = frame.maxY + ScoreLayout.pageGap
            }

            pageFrames = frames
            pagesSystems = perPage
            systems = perPage.flatMap { $0 }
            totalHeight = y
        }
    }

    func box(forMeasure index: Int) -> (system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        for system in systems {
            if let box = system.measures.first(where: { $0.index == index }) { return (system, box) }
        }

        return nil
    }

    /// The playhead cursor's frame at `units` into measure `measure`: a line and a half wide, a
    /// staff space past the system's outer staves; nil off the layout.
    func cursorFrame(measure: Int, units: Double) -> CGRect? {
        guard let (system, box) = box(forMeasure: measure) else { return nil }

        let x = box.x(forUnits: units)
        let top = system.staffTop - sp
        let bottom = system.staffBottom + sp

        return CGRect(x: (x - 0.75).rounded(), y: top, width: 1.5, height: bottom - top)
    }

    /// The measure and the position in it under `point`, or nil off the music.
    func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        let slack = ScoreSystemLayout.systemGap * sp / 2

        for system in systems where point.y >= system.frame.minY - slack && point.y <= system.frame.maxY + slack {
            for box in system.measures where point.x >= box.x && point.x < box.endX {
                return (box.index, box.units(forX: point.x))
            }

            if let first = system.measures.first, point.x < first.x { return (first.index, 0) }
            if let last = system.measures.last, point.x >= last.endX { return (last.index, Double(last.onsets.last?.units ?? 0)) }
        }

        return nil
    }
}
