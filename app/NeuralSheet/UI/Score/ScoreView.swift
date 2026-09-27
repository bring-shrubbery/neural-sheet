import AppKit
import NeuralSheetCore

/// The page (score design §5, arrangement design §4): a ``ScoreLayout`` drawn by a
/// ``ScoreRenderer``, with the cursor as a subview so the playhead moves without a repaint, the
/// tab notes as drawn kept for the click, and the selected one outlined. Sized by its container
/// to the layout's height.
final class ScoreView: NSView {
    var document = ScoreDocument.empty
    var arrangement = ScoreArrangement()
    var layout: ScoreLayout? {
        didSet { hitsBySystem = [:] }
    }

    /// The tab notes as drawn, by system: the systems drawn so far with this layout, which
    /// covers everything a click can land on. Kept per system because a tall view is tiled and
    /// `draw(_:)` may cover one tile's systems at a time.
    private var hitsBySystem: [Int: [TabHit]] = [:]
    var hits: [TabHit] { hitsBySystem.values.flatMap { $0 } }
    var selectedTabNote: (program: Int, id: NoteID)?

    /// A click on empty score seeks; the container owns the model.
    var onSeek: ((Int, Double) -> Void)?
    /// A click on a tab note selects it; a click elsewhere clears the selection (`nil`).
    var onSelectTabNote: ((TabHit?) -> Void)?
    /// A right-click on a tab note, with the point in the window.
    var onRightClickTabNote: ((TabHit, NSPoint) -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        guard let layout else { return }

        let point = convert(event.locationInWindow, from: nil)

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

        ctx.fill(rect.intersection(bounds), ScorePalette.paper)

        guard let layout else { return }

        let renderer = ScoreRenderer(document: document, arrangement: arrangement, sp: layout.sp)

        for (index, system) in layout.systems.systems.enumerated() where system.frame.insetBy(dx: 0, dy: -8 * layout.sp).intersects(rect) {
            var collected: [TabHit] = []
            renderer.drawSystem(system, in: ctx, hits: &collected)
            hitsBySystem[index] = collected
        }

        if let selected = selectedTabNote, let hit = hits.first(where: { $0.program == selected.program && $0.id == selected.id }) {
            ctx.setStrokeColor(ScorePalette.selectionEdge)
            ctx.setLineWidth(max(1, layout.sp / 8))
            ctx.stroke(hit.frame.insetBy(dx: -layout.sp * 0.15, dy: -layout.sp * 0.15))
        }
    }
}
