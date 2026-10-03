import AppKit
import NeuralSheetCore

/// The piano roll (`PianoRoll`): one lane per semitone on show, the notes in their instruments'
/// colours, the wash left of the playhead and the shade past the decode frontier. In the Edit tab
/// the tempo grid runs over the lanes and each note's velocity shows in its alpha (design §6.5).
///
/// The lanes are measured off the same geometry the key column is drawn with. What is drawn and
/// how is ``RollPainter``'s (`PianoRollView+Drawing.swift`), shared with the iPhone and iPad app;
/// this view holds one and adds the overlays, the mouse and VoiceOver.
final class PianoRollView: NSView {
    let geometry: TimelineGeometry

    /// The drawing's state and the drawing itself.
    var painter: RollPainter

    /// Nothing is drawn unless the transport can play (`PianoRoll::paint`).
    var canPlay: Bool {
        get { painter.canPlay }
        set {
            if newValue != painter.canPlay {
                painter.canPlay = newValue
                needsDisplay = true
            }
        }
    }

    /// The tempo grid drawn over the lanes, in the Edit tab; nil draws none. Whole-view repaint:
    /// the caller decides.
    var grid: TempoGrid? {
        get { painter.grid }
        set { painter.grid = newValue }
    }

    /// The project's key, whose scale colours the lanes in both tabs (key design §5); nil
    /// colours them by key colour. Whole-view repaint: the caller decides.
    var key: MusicalKey? {
        get { painter.key }
        set { painter.key = newValue }
    }

    /// View → Show Confidence (confidence design §2): notes shade by how sure the model was, in
    /// both tabs, in place of velocity. Whole-view repaint: the caller decides.
    var showsConfidence: Bool {
        get { painter.showsConfidence }
        set { painter.showsConfidence = newValue }
    }

    /// View → Show Pitch Curves (pitch curves design §2): a tracked note's curve is drawn through
    /// it, in both tabs. Whole-view repaint: the caller decides.
    var showsPitchCurves: Bool {
        get { painter.showsPitchCurves }
        set { painter.showsPitchCurves = newValue }
    }

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    /// The edit controller, in Edit mode; without one a click seeks.
    weak var interaction: RollEditController?
    /// Where the last right press landed, so its release resolves there.
    private var rightPressPoint: CGPoint?

    let playhead = PlayheadView(drawsTriangle: false)
    let wash = FillView(colour: TimelinePalette.accentWashRoll)
    let frontierShade = FillView(colour: TimelinePalette.frontierShade)
    let frontierLine = FillView(colour: TimelinePalette.divStrong)
    let marquee = MarqueeView(frame: .zero)
    let rangeBand = RangeBandView(frame: .zero)

    var notes: [NoteEvent] { painter.notes }
    /// `ids[i]` identifies `notes[i]`; placeholder ids while a run streams (nothing hit-tests them).
    var ids: [NoteID] { painter.ids }

    /// `buckets[s]` holds the indices of every note drawn over second `s`, in note order.
    var buckets: [[Int]] { painter.buckets }

    /// Per program: whether it is heard, and the colour it draws in.
    var audible: [Bool] { painter.audible }
    var colours: [CGColor] { painter.colours }

    /// The instrument a strip click singled out: every other instrument fades while it is set.
    var highlightedProgram: Int? { painter.highlightedProgram }

    /// Design §6.5: the selection's outline, a drag's preview, and the indices the preview names.
    var selection: Set<NoteID> { painter.selection }
    var preview: DragPreview? { painter.preview }
    var previewIndices: [Int] { painter.previewIndices }

    /// The compared version's notes, drawn hollow under the notes (versions design §2).
    var ghosts: GhostNotes { painter.ghosts }

    private var trackingArea: NSTrackingArea?

    /// VoiceOver's notes for the band, made when it asks and dropped when the notes or the band
    /// change (`+Accessibility`); the model's side of their actions.
    var accessibilityNotes: [DrawnElement]?
    weak var accessibilityHandler: RollAccessibilityHandler?

    /// The painter's constants, by the names the rest of the app knows them by.
    static let drumMinDrawnSeconds = RollPainter.drumMinDrawnSeconds
    static let mutedNoteAlpha = RollPainter.mutedNoteAlpha
    static let unhighlightedNoteAlpha = RollPainter.unhighlightedNoteAlpha
    static let noteCorner = RollPainter.noteCorner
    static let onsetEdgeWidth = RollPainter.onsetEdgeWidth
    static let selectionOutlineWidth = RollPainter.selectionOutlineWidth
    static let ghostAlpha = RollPainter.ghostAlpha
    static let lyricInset = RollPainter.lyricInset
    static let lyricMinHeight = RollPainter.lyricMinHeight

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        painter = RollPainter(geometry: geometry)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true

        // The order `PianoRoll::paint` draws them in, over the lanes and the notes; the marquee
        // under the playhead so the line stays on top.
        addSubview(wash)
        addSubview(frontierShade)
        addSubview(frontierLine)
        addSubview(rangeBand)
        addSubview(marquee)
        addSubview(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    // MARK: - Content

    /// Replaces the notes and rebuilds the second buckets. Whole-view repaint: the caller decides.
    /// A note with a non-finite time cannot be placed and is left out rather than trapped on.
    func setNotes(_ newNotes: [EditableNote]) {
        let placeable = newNotes.filter { $0.note.startTime.isFinite && $0.note.endTime.isFinite }
        painter.notes = placeable.map(\.note)
        painter.ids = placeable.map(\.id)
        painter.buckets = RollPainter.secondBuckets(painter.notes)
        painter.refreshPreviewIndices()
        invalidateAccessibilityNotes()
    }

    var hasNotes: Bool { painter.hasNotes }

    /// Repaints the notes whose outline changes.
    func setSelection(_ new: Set<NoteID>) {
        guard new != selection else { return }

        painter.selection = new
        setNeedsDisplay(visibleRect)
        accessibilitySelectionDidChange()
    }

    /// The drag in progress, or nil once it ends; the named notes are drawn where they would land.
    func setPreview(_ new: DragPreview?) {
        guard new != preview else { return }

        painter.preview = new
        painter.refreshPreviewIndices()
        setNeedsDisplay(visibleRect)
    }

    /// Which instruments are heard, from the mixer. Repaints only if something changed.
    func setMixer(_ mixer: InstrumentMixerState) {
        var changed = false

        for program in 0...NoteEvent.drumProgram {
            let isAudible = mixer.isAudible(program: program)

            if painter.audible[program] != isAudible {
                painter.audible[program] = isAudible
                changed = true
            }
        }

        if changed {
            needsDisplay = true
        }
    }

    /// The instrument singled out from the sidebar, or nil for none. Repaints what is on screen.
    func setHighlightedProgram(_ program: Int?) {
        guard program != highlightedProgram else { return }

        painter.highlightedProgram = program
        setNeedsDisplay(visibleRect)
    }

    static func drawnEnd(of note: NoteEvent) -> Double {
        RollPainter.drawnEnd(of: note)
    }

    // MARK: - Overlays

    func configure() {
        playhead.configure(scale: geometry.scale, height: bounds.height)
        marquee.scale = geometry.scale
        rangeBand.scale = geometry.scale
    }

    /// The playhead and the wash left of it; nil hides both (`PianoRoll::updateEnablements`).
    func setPlayhead(x: CGFloat?) {
        guard let x else {
            playhead.isHidden = true
            wash.isHidden = true
            return
        }

        playhead.isHidden = false
        playhead.move(toX: x)

        let washed = x > 0
        wash.isHidden = !washed

        if washed {
            wash.set(frame: CGRect(x: 0, y: 0, width: x, height: bounds.height))
        }
    }

    /// `PianoRoll::_drawTranscriptionFrontier`: everything right of `seconds` is shaded while a
    /// transcription runs; nil while it does not.
    func setFrontier(seconds: Double?) {
        guard let seconds else {
            frontierShade.isHidden = true
            frontierLine.isHidden = true
            return
        }

        // To the end of the band's window; the container lays the shade out again when it slides.
        let end = bounds.maxX
        let x = geometry.x(forSeconds: seconds)

        guard x < end else {
            frontierShade.isHidden = true
            frontierLine.isHidden = true
            return
        }

        frontierShade.isHidden = false
        frontierLine.isHidden = false
        frontierShade.set(frame: CGRect(x: x, y: 0, width: end - x, height: bounds.height))

        let lineX = (x / geometry.scale).rounded() * geometry.scale
        frontierLine.set(frame: CGRect(x: lineX, y: 0, width: geometry.scale, height: bounds.height))
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        painter.draw(ctx, in: rect.intersection(bounds), bounds: bounds)
    }

    // MARK: - Mouse

    /// The tool's base cursor for the whole roll; `mouseMoved` and `cursorUpdate` refine it over
    /// edges. Without an installed interaction the roll has no cursor rect and AppKit's arrow
    /// stands.
    override func resetCursorRects() {
        guard let interaction else { return }

        addCursorRect(visibleRect, cursor: interaction.cursor(at: CGPoint(x: -1, y: -1)))
    }

    /// Tracks the pointer for the edit cursor; `mouseMoved` and `cursorUpdate` ask the controller.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The first click on the roll while the note card is key is a click, not a focus change.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A field that had the keyboard commits and lets go, so Space is the transport's again.
        window?.makeFirstResponder(nil)

        let point = convert(event.locationInWindow, from: nil)

        if let interaction {
            interaction.mouseDown(at: point, event: event)
        } else {
            onSeek?(geometry.seconds(forX: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        interaction?.mouseDragged(at: convert(event.locationInWindow, from: nil), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        interaction?.mouseUp(at: convert(event.locationInWindow, from: nil), event: event)
    }

    /// A right click on a note selects like a click, and anywhere on the roll it opens the card
    /// for the selection (design §7): the up resolves the press at the point it went down,
    /// however far the mouse moved in between, so a right press-move-release never turns into a
    /// move, a resize, a marquee or an erase that showed no preview. A right drag is not
    /// forwarded.
    override func rightMouseDown(with event: NSEvent) {
        guard let interaction else { return super.rightMouseDown(with: event) }

        window?.makeFirstResponder(nil)

        let point = convert(event.locationInWindow, from: nil)
        rightPressPoint = point
        interaction.mouseDown(at: point, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let interaction else { return super.rightMouseUp(with: event) }

        let point = rightPressPoint ?? convert(event.locationInWindow, from: nil)
        rightPressPoint = nil
        interaction.mouseUp(at: point, event: event)
    }
}
