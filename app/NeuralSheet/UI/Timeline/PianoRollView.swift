import AppKit
import NeuralSheetCore

/// The piano roll (`PianoRoll`): one lane per semitone on show, the notes in their instruments'
/// colours, the wash left of the playhead and the shade past the decode frontier. In the Edit tab
/// the tempo grid runs over the lanes and each note's velocity shows in its alpha (design §6.5).
///
/// The lanes are measured off the same geometry the key column is drawn with. Notes are bucketed by
/// second so a repaint of one sliver — the playhead moving, a chunk landing — touches only the
/// notes that cross it, never the whole transcription.
final class PianoRollView: NSView {
    let geometry: TimelineGeometry

    /// Nothing is drawn unless the transport can play (`PianoRoll::paint`).
    var canPlay = false {
        didSet {
            if canPlay != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The tempo grid drawn over the lanes, in the Edit tab; nil draws none. Whole-view repaint:
    /// the caller decides.
    var grid: TempoGrid?

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

    private(set) var notes: [NoteEvent] = []
    /// `ids[i]` identifies `notes[i]`; placeholder ids while a run streams (nothing hit-tests them).
    private(set) var ids: [NoteID] = []

    /// `buckets[s]` holds the indices of every note drawn over second `s`, in note order.
    private(set) var buckets: [[Int]] = []

    /// Per program: whether it is heard, and the colour it draws in.
    private(set) var audible = [Bool](repeating: true, count: NoteEvent.drumProgram + 1)
    private(set) var colours: [CGColor] = []

    /// Design §6.5: the selection's outline, a drag's preview, and the indices the preview names.
    private(set) var selection: Set<NoteID> = []
    private(set) var preview: DragPreview?
    var previewIndices: [Int] = []

    private var trackingArea: NSTrackingArea?

    /// How far a drum hit is widened for drawing (`DRUM_MIN_DRAWN_SECONDS`).
    static let drumMinDrawnSeconds = 0.1
    static let mutedNoteAlpha: CGFloat = 0.16
    static let noteCorner: CGFloat = 2
    static let onsetEdgeWidth: CGFloat = 2

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true

        // The order `PianoRoll::paint` draws them in, over the lanes and the notes; the marquee
        // under the playhead so the line stays on top.
        addSubview(wash)
        addSubview(frontierShade)
        addSubview(frontierLine)
        addSubview(marquee)
        addSubview(playhead)

        colours = (0...NoteEvent.drumProgram).map { program in
            TimelinePalette.cg(Instruments.info(forProgram: program).colour, alpha: 1)
        }
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
        notes = placeable.map(\.note)
        ids = placeable.map(\.id)
        rebuildBuckets()
        refreshPreviewIndices()
    }

    private func rebuildBuckets() {
        let seconds = Int((notes.map { PianoRollView.drawnEnd(of: $0) }.max() ?? 0).rounded(.up)) + 1
        var newBuckets = [[Int]](repeating: [], count: max(1, seconds))

        for (index, note) in notes.enumerated() {
            let first = max(0, Int(note.startTime))
            let last = max(first, Int(PianoRollView.drawnEnd(of: note)))

            for bucket in first...min(last, newBuckets.count - 1) {
                newBuckets[bucket].append(index)
            }
        }

        buckets = newBuckets
    }

    var hasNotes: Bool { !notes.isEmpty }

    /// Repaints the notes whose outline changes.
    func setSelection(_ new: Set<NoteID>) {
        guard new != selection else { return }

        selection = new
        setNeedsDisplay(visibleRect)
    }

    /// The drag in progress, or nil once it ends; the named notes are drawn where they would land.
    func setPreview(_ new: DragPreview?) {
        guard new != preview else { return }

        preview = new
        refreshPreviewIndices()
        setNeedsDisplay(visibleRect)
    }

    /// Which instruments are heard, from the mixer. Repaints only if something changed.
    func setMixer(_ mixer: InstrumentMixerState) {
        var changed = false

        for program in 0...NoteEvent.drumProgram {
            let isAudible = mixer.isAudible(program: program)

            if audible[program] != isAudible {
                audible[program] = isAudible
                changed = true
            }
        }

        if changed {
            needsDisplay = true
        }
    }

    static func drawnEnd(of note: NoteEvent) -> Double {
        note.isDrum ? max(note.endTime, note.startTime + drumMinDrawnSeconds) : note.endTime
    }

    // MARK: - Overlays

    func configure() {
        playhead.configure(scale: geometry.scale, height: bounds.height)
        marquee.scale = geometry.scale
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

        let width = bounds.width
        let x = geometry.x(forSeconds: seconds)

        guard x < width else {
            frontierShade.isHidden = true
            frontierLine.isHidden = true
            return
        }

        frontierShade.isHidden = false
        frontierLine.isHidden = false
        frontierShade.set(frame: CGRect(x: x, y: 0, width: width - x, height: bounds.height))

        let lineX = (x / geometry.scale).rounded() * geometry.scale
        frontierLine.set(frame: CGRect(x: lineX, y: 0, width: geometry.scale, height: bounds.height))
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dirtyRect = rect.intersection(bounds)

        ctx.fill(dirtyRect, TimelinePalette.bgRoot)

        guard canPlay else { return }

        drawLanes(ctx, in: dirtyRect)
        drawNotes(ctx, in: dirtyRect)
    }

    /// `PianoRoll::_drawLanes`: `laneWhite` / `laneBlack` by key colour, held back to 55 % while
    /// there is nothing on them, and a 1 px `divOctave` separator under every C.
    private func drawLanes(_ ctx: CGContext, in dirtyRect: CGRect) {
        let k = geometry.scale
        let range = geometry.pitchRange
        let column = CGRect(x: 0, y: 0, width: TimelineMetrics.gutterWidth * k, height: geometry.keyboardHeight * k)
        let empty = !hasNotes

        for note in range.low...range.high {
            // Only the keys inside the column, which is what the keyboard shows too.
            guard geometry.keyRect(note).intersects(column) else { continue }

            let lane = geometry.lane(forPitch: note)
            let laneRect = CGRect(x: dirtyRect.minX, y: lane.y, width: dirtyRect.width, height: lane.height)

            guard laneRect.intersects(dirtyRect) else { continue }

            let white = !KeyboardLayout.isBlack(note)
            let colour = empty
                ? (white ? TimelinePalette.laneWhiteEmpty : TimelinePalette.laneBlackEmpty)
                : (white ? TimelinePalette.laneWhite : TimelinePalette.laneBlack)

            ctx.fill(laneRect, colour)

            // An octave separator on each C, which is the only thing standing in for the vertical
            // grid the Transcribe tab deliberately does without.
            if note % 12 == 0 {
                ctx.fill(CGRect(x: dirtyRect.minX, y: lane.y + lane.height - k, width: dirtyRect.width, height: k),
                         empty ? TimelinePalette.divOctaveEmpty : TimelinePalette.divOctave)
            }
        }

        if let grid {
            drawGrid(ctx, grid: grid, in: dirtyRect)
        }
    }

    /// Design §6.5: bar, beat and division lines over the lanes; the finer kinds drop out as
    /// they crowd.
    private func drawGrid(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect) {
        let k = geometry.scale
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let divisionPixels = grid.step * pixelsPerSecond
        let beatPixels = grid.secondsPerBeat * pixelsPerSecond
        let drawDivisions = divisionPixels >= 6
        let drawBeats = beatPixels >= 3
        // A division coarser than a beat still shows the beats.
        let division: GridDivision = drawDivisions && grid.division.beats < 1 ? grid.division : .quarter

        // One authored pixel of slack on the left: a line's x is rounded, so one just outside the
        // sliver can land inside it.
        for line in grid.lines(from: max(0, geometry.seconds(forX: dirtyRect.minX - k)),
                               to: geometry.seconds(forX: dirtyRect.maxX), division: division) {
            let colour: CGColor

            switch line.kind {
            case .bar: colour = TimelinePalette.divStrong
            case .beat where drawBeats: colour = TimelinePalette.divOctave
            case .division where drawDivisions: colour = TimelinePalette.gridDivision
            default: continue
            }

            let x = CGFloat((line.seconds * pixelsPerSecond).rounded()) * k
            ctx.fill(CGRect(x: x, y: dirtyRect.minY, width: k, height: dirtyRect.height), colour)
        }
    }

    /// `PianoRoll::_drawNotes`, over the notes whose seconds cross the exposed sliver; then the
    /// notes a drag previews, wherever they land now, and the Draw tool's note in progress.
    private func drawNotes(_ ctx: CGContext, in dirtyRect: CGRect) {
        let previewSet = Set(previewIndices)

        for index in indices(crossing: dirtyRect) where !previewSet.contains(index) {
            let note = notes[index]

            guard let rect = noteRect(note), rect.maxX >= dirtyRect.minX, rect.minX <= dirtyRect.maxX else { continue }

            drawNote(note, in: rect, selected: selection.contains(ids[index]), ctx: ctx)
        }

        // The preview's notes, wherever they land now. Not clipped to the sliver: the preview
        // invalidates the whole visible rect, and a moved note has to leave where it was.
        for index in previewIndices {
            let original = notes[index]

            if previewDuplicates, let rect = noteRect(original) {
                drawNote(original, in: rect, selected: false, ctx: ctx)
            }

            guard let shown = previewed(original, id: ids[index]), let rect = noteRect(shown) else { continue }

            drawNote(shown, in: rect, selected: true, ctx: ctx)
        }

        if let drawn = drawnPreview, let rect = noteRect(drawn) {
            drawNote(drawn, in: rect, selected: true, ctx: ctx)
        }
    }

    /// The indices of the notes whose seconds cross `dirtyRect`, in note order.
    private func indices(crossing dirtyRect: CGRect) -> [Int] {
        guard !notes.isEmpty, !buckets.isEmpty else { return [] }

        let fromSeconds = max(0, geometry.seconds(forX: dirtyRect.minX))
        let toSeconds = geometry.seconds(forX: dirtyRect.maxX)
        let firstBucket = min(Int(fromSeconds), buckets.count - 1)
        let lastBucket = min(Int(toSeconds), buckets.count - 1)

        guard firstBucket <= lastBucket else { return [] }

        // Gathered and sorted rather than drawn bucket by bucket, so overlapping notes stack in the
        // order the transcription lists them, wherever their buckets start.
        var indices: [Int] = []

        for bucket in firstBucket...lastBucket {
            for index in buckets[bucket] {
                let note = notes[index]
                let startBucket = max(0, Int(note.startTime))

                if bucket == max(startBucket, firstBucket) {
                    indices.append(index)
                }
            }
        }

        indices.sort()

        return indices
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

    override func mouseDown(with event: NSEvent) {
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

    /// A right click selects like a click (design §7): the up resolves the press at the point it
    /// went down, however far the mouse moved in between, so a right press-move-release never
    /// turns into a move, a resize, a marquee or an erase that showed no preview. A right drag
    /// is not forwarded.
    override func rightMouseDown(with event: NSEvent) {
        guard let interaction else { return super.rightMouseDown(with: event) }

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
