import AppKit
import NeuralSheetCore

/// The score (score design §5, arrangement design §4, §6): a ``ScoreLayout`` drawn by a
/// ``ScoreRenderer`` — the systems down a continuous column, or the pages on their surround —
/// with the cursor as a subview so the playhead moves without a repaint, the tab notes and the
/// part names as drawn kept for the click, and the selected note outlined. Sized by its
/// container to the layout's height.
final class ScoreView: NSView {
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

    /// The tab notes and the part names as drawn, by system: the systems drawn so far with this
    /// layout, which covers everything a click can land on. Kept per system because a tall view
    /// is tiled and `draw(_:)` may cover one tile's systems at a time; flattened in system order
    /// so the first hit found is the same whatever order the tiles were drawn in. In pages mode
    /// a page is drawn whole and its hits go under its first system's index; a page's systems
    /// are contiguous, so the order holds.
    private var hitsBySystem: [Int: [TabHit]] = [:]
    private var namesBySystem: [Int: [NameHit]] = [:]
    var hits: [TabHit] { hitsBySystem.keys.sorted().flatMap { hitsBySystem[$0] ?? [] } }
    var nameHits: [NameHit] { namesBySystem.keys.sorted().flatMap { namesBySystem[$0] ?? [] } }
    var selectedTabNote: (program: Int, id: NoteID)?

    /// A click on empty score seeks; the container owns the model.
    var onSeek: ((Int, Double) -> Void)?
    /// A click on a tab note selects it; a click elsewhere clears the selection (`nil`).
    var onSelectTabNote: ((TabHit?) -> Void)?
    /// A right-click on a tab note, with the point in the window.
    var onRightClickTabNote: ((TabHit, NSPoint) -> Void)?
    /// A click on a part's name, with the program and the point in the window.
    var onClickPartName: ((Int, NSPoint) -> Void)?

    let cursor = FillView(colour: ScorePalette.cursor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(cursor)
        cursor.isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Puts the cursor at `units` into measure `measure`, or hides it.
    func placeCursor(measure: Int?, units: Double) {
        guard let layout, let measure, let (system, box) = layout.box(forMeasure: measure) else {
            cursor.isHidden = true
            return
        }

        let x = box.x(forUnits: units)
        let top = system.staffTop - layout.sp
        let bottom = system.staffBottom + layout.sp

        cursor.isHidden = false
        cursor.set(frame: CGRect(x: (x - 0.75).rounded(), y: top, width: 1.5, height: bottom - top))
    }

    // MARK: - Clicks

    /// The tab note under `point`, with a little slack around its number.
    private func hit(at point: NSPoint) -> TabHit? {
        hits.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// The part name under `point`.
    private func nameHit(at point: NSPoint) -> NameHit? {
        nameHits.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        guard let layout else { return }

        let point = convert(event.locationInWindow, from: nil)

        if let name = nameHit(at: point) {
            onClickPartName?(name.program, event.locationInWindow)
            return
        }

        if let hit = hit(at: point) {
            onSelectTabNote?(hit)
            return
        }

        onSelectTabNote?(nil)

        if let hit = layout.hitTest(point) {
            onSeek?(hit.measure, hit.units)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let hit = hit(at: point) {
            onRightClickTabNote?(hit, event.locationInWindow)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        guard let layout else {
            ctx.fill(rect.intersection(bounds), ScorePalette.paper)
            return
        }

        let renderer = ScoreRenderer(document: document, arrangement: arrangement, sp: layout.sp)

        switch layout.mode {
        case .continuous:
            ctx.fill(rect.intersection(bounds), ScorePalette.paper)

            for (index, system) in layout.systems.enumerated() where system.frame.insetBy(dx: 0, dy: -8 * layout.sp).intersects(rect) {
                var collected: [TabHit] = []
                var names: [NameHit] = []
                renderer.drawSystem(system, in: ctx, hits: &collected, names: &names)
                hitsBySystem[index] = collected
                namesBySystem[index] = names
            }

        case .pages:
            ctx.fill(rect.intersection(bounds), ScoreView.surround)

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
            ctx.setStrokeColor(ScorePalette.selectionEdge)
            ctx.setLineWidth(max(1, layout.sp / 8))
            ctx.stroke(hit.frame.insetBy(dx: -layout.sp * 0.15, dy: -layout.sp * 0.15))
        }
    }

    /// The grey behind the pages (arrangement design §6).
    static let surround = TimelinePalette.cg(Theme.bgPanel)
}
