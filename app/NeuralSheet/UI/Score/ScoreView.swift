import AppKit
import NeuralSheetCore

/// The score (score design §5, arrangement design §4, §6): a ``ScoreLayout`` drawn by a
/// ``ScoreRenderer`` — the systems down a continuous column, or the pages on their surround —
/// with the cursor as a subview so the playhead moves without a repaint, the tab notes and the
/// part names as drawn kept for the click, and the selected note outlined. Sized by its
/// container to the layout's height.
final class ScoreView: NSView {
    /// The drawing and the hits as drawn (`+Drawing`), shared with the iPhone and iPad score.
    private var painter = ScorePainter()

    var document: ScoreDocument {
        get { painter.document }
        set { painter.document = newValue }
    }

    var arrangement: ScoreArrangement {
        get { painter.arrangement }
        set { painter.arrangement = newValue }
    }

    /// The take's file name, the title's fallback on the first page's header.
    var takeName: String? {
        get { painter.takeName }
        set { painter.takeName = newValue }
    }

    var layout: ScoreLayout? {
        get { painter.layout }
        set {
            painter.layout = newValue
            invalidateAccessibilitySystems()
        }
    }

    /// VoiceOver's systems, made when it asks and dropped with the layout (`+Accessibility`).
    var accessibilitySystems: [DrawnElement]?

    var hits: [TabHit] { painter.hits }
    var nameHits: [NameHit] { painter.nameHits }

    var selectedTabNote: (program: Int, id: NoteID)? {
        get { painter.selectedTabNote }
        set { painter.selectedTabNote = newValue }
    }

    /// A click on empty score seeks; the container owns the model.
    var onSeek: ((Int, Double) -> Void)?
    /// A click on a tab note selects it; a click elsewhere clears the selection (`nil`).
    var onSelectTabNote: ((TabHit?) -> Void)?
    /// A right-click on a tab note, with the point in the window.
    var onRightClickTabNote: ((TabHit, NSPoint) -> Void)?
    /// A click on a part's name, with the program and the point in the window.
    var onClickPartName: ((Int, NSPoint) -> Void)?
    /// A right-click on a chord symbol (chord symbols design §2), with its index in the list and
    /// the point in the window.
    var onRightClickChord: ((Int, NSPoint) -> Void)?

    let cursor = FillView(colour: ScoreRenderer.Style.screen.cursor)

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
        guard let layout, let measure, let frame = layout.cursorFrame(measure: measure, units: units) else {
            cursor.isHidden = true
            return
        }

        cursor.isHidden = false
        cursor.set(frame: frame)
    }

    // MARK: - Clicks

    private func hit(at point: NSPoint) -> TabHit? {
        painter.hit(at: point)
    }

    private func chordHit(at point: NSPoint) -> ChordHit? {
        painter.chordHit(at: point)
    }

    private func nameHit(at point: NSPoint) -> NameHit? {
        painter.nameHit(at: point)
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
        } else if let chord = chordHit(at: point) {
            onRightClickChord?(chord.index, event.locationInWindow)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        painter.draw(rect, bounds: bounds, in: ctx)
    }
}
