import CoreGraphics
import NeuralSheetCore

/// The score view's drawing (arrangement design §4, §6), apart from the view so the Mac's
/// ``ScoreView`` and the iPhone and iPad score draw the same pixels: the paper or the surround,
/// the systems or the pages through a ``ScoreRenderer``, and the selected tab note's outline.
/// It keeps the tab notes and the part names as drawn for the clicks and the taps.
struct ScorePainter {
    var document = ScoreDocument.empty
    var arrangement = ScoreArrangement()
    /// The take's file name, the title's fallback on the first page's header.
    var takeName: String?
    var layout: ScoreLayout? {
        didSet {
            hitsBySystem = [:]
            namesBySystem = [:]
        }
    }

    var selectedTabNote: (program: Int, id: NoteID)?

    /// The tab notes and the part names as drawn, by system: the systems drawn so far with this
    /// layout, which covers everything a click can land on. Kept per system because a tall view
    /// is tiled and a draw may cover one tile's systems at a time; flattened in system order so
    /// the first hit found is the same whatever order the tiles were drawn in. In pages mode a
    /// page is drawn whole and its hits go under its first system's index; a page's systems are
    /// contiguous, so the order holds.
    private var hitsBySystem: [Int: [TabHit]] = [:]
    private var namesBySystem: [Int: [NameHit]] = [:]
    var hits: [TabHit] { hitsBySystem.keys.sorted().flatMap { hitsBySystem[$0] ?? [] } }
    var nameHits: [NameHit] { namesBySystem.keys.sorted().flatMap { namesBySystem[$0] ?? [] } }

    // MARK: - Hits

    /// The tab note under `point`, with a little slack around its number.
    func hit(at point: CGPoint) -> TabHit? {
        hits.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// The chord symbol under `point`, placed as the renderer places it.
    func chordHit(at point: CGPoint) -> ChordHit? {
        guard let layout else { return nil }

        let renderer = ScoreRenderer(document: document, arrangement: arrangement, sp: layout.sp)

        for system in layout.systems where system.frame.insetBy(dx: 0, dy: -8 * layout.sp).contains(point) {
            if let hit = renderer.chordHits(system).first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }) {
                return hit
            }
        }

        return nil
    }

    /// The part name under `point`.
    func nameHit(at point: CGPoint) -> NameHit? {
        nameHits.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    // MARK: - Drawing

    /// Everything that meets `rect` of a view `bounds` big, into `ctx` (y down).
    mutating func draw(_ rect: CGRect, bounds: CGRect, in ctx: CGContext) {
        guard let layout else {
            ctx.fill(rect.intersection(bounds), ScoreRenderer.Style.screen.paper)
            return
        }

        let renderer = ScoreRenderer(document: document, arrangement: arrangement, sp: layout.sp)

        switch layout.mode {
        case .continuous:
            ctx.fill(rect.intersection(bounds), ScoreRenderer.Style.screen.paper)

            for (index, system) in layout.systems.enumerated() where system.frame.insetBy(dx: 0, dy: -8 * layout.sp).intersects(rect) {
                var collected: [TabHit] = []
                var names: [NameHit] = []
                renderer.drawSystem(system, in: ctx, hits: &collected, names: &names)
                hitsBySystem[index] = collected
                namesBySystem[index] = names
            }

        case .pages:
            ctx.fill(rect.intersection(bounds), ScoreLayout.surround)

            guard let pages = layout.pages else { break }

            var nextSystemIndex = 0

            for (pageIndex, frame) in layout.pageFrames.enumerated() {
                let systems = layout.pagesSystems[pageIndex]
                let firstSystemIndex = nextSystemIndex
                nextSystemIndex += systems.count

                guard frame.intersects(rect) else { continue }

                var collected: [TabHit] = []
                var names: [NameHit] = []
                renderer.drawPage(pages.pages[pageIndex], frame: frame, systems: systems, takeName: takeName,
                                  scale: layout.scale, in: ctx, hits: &collected, names: &names)
                hitsBySystem[firstSystemIndex] = collected
                namesBySystem[firstSystemIndex] = names
            }
        }

        if let selected = selectedTabNote, let hit = hits.first(where: { $0.program == selected.program && $0.id == selected.id }) {
            ctx.setStrokeColor(ScoreRenderer.Style.screen.selectionEdge)
            ctx.setLineWidth(max(1, layout.sp / 8))
            ctx.stroke(hit.frame.insetBy(dx: -layout.sp * 0.15, dy: -layout.sp * 0.15))
        }
    }
}
