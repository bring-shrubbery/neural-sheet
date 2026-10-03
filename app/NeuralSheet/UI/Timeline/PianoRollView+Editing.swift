import AppKit
import NeuralSheetCore

/// What the pointer landed on.
struct RollHit: Equatable {
    var id: NoteID
    var zone: NoteHitZone
    var note: NoteEvent
}

/// A drag in progress, as the roll draws it (design §6.5): the document is untouched until the
/// mouse goes up, so the roll shows the affected notes where they would land.
struct DragPreview: Equatable {
    enum Kind: Equatable {
        case transform(deltaSeconds: Double, deltaSemitones: Int, duplicating: Bool)
        case resize(edge: NoteEdge, deltaSeconds: Double)
        case erase
        case draw(NoteEvent)
    }

    var kind: Kind
    var ids: Set<NoteID>
}

/// The accent-outlined rubber band. Positioned, never repainted.
final class MarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TimelinePalette.marqueeFill
        layer?.borderColor = TimelinePalette.marqueeBorder
        layer?.borderWidth = scale
    }

    var scale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The roll's side of editing: hit testing, the selection outline and the drag preview.
extension PianoRollView {
    static let selectionOutlineWidth: CGFloat = 1.5

    // MARK: - Selection and preview

    /// The indices of the notes the preview names, so they can be drawn wherever they land
    /// rather than only from the buckets of where they were.
    func refreshPreviewIndices() {
        guard let preview else {
            previewIndices = []
            return
        }

        previewIndices = ids.indices.filter { preview.ids.contains(ids[$0]) }
    }

    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        guard let interaction else { return }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let interaction else {
            super.cursorUpdate(with: event)
            return
        }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// The tool changed under a still pointer: the cursor follows without a mouse move.
    func refreshCursor() {
        guard let interaction, let window else { return }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)

        if visibleRect.contains(point) {
            interaction.cursor(at: point).set()
        }
    }

    // MARK: - Geometry

    /// The rect a note is drawn in, or nil when its pitch is off the range.
    func noteRect(_ note: NoteEvent) -> CGRect? {
        let k = geometry.scale
        let range = geometry.pitchRange

        // The range always covers the whole transcription, so this only skips a note in the
        // window between it arriving and the range being told about it.
        guard note.pitch >= range.low, note.pitch <= range.high else { return nil }

        let lane = geometry.lane(forPitch: note.pitch)

        guard lane.y >= 0, lane.height < bounds.height else { return nil }

        let x = geometry.x(forSeconds: note.startTime)
        let width = max(1 * k, geometry.x(forSeconds: PianoRollView.drawnEnd(of: note)) - x - 1 * k)

        return CGRect(x: x, y: lane.y, width: width, height: lane.height)
    }

    /// The topmost note under `point` and where on it.
    func hit(at point: CGPoint) -> RollHit? {
        guard !buckets.isEmpty else { return nil }

        let k = geometry.scale
        let second = Int(max(0, geometry.seconds(forX: point.x)))

        guard second < buckets.count else { return nil }

        // Last drawn is topmost: walk the bucket backwards.
        for index in buckets[second].reversed() {
            let note = notes[index]

            guard let rect = noteRect(note),
                  let zone = EditGestureMath.hitZone(in: rect, at: point, edgeWidth: RollEditController.edgeWidth * k,
                                                     minimumWidthForEdges: RollEditController.minimumWidthForEdges * k)
            else { continue }

            return RollHit(id: ids[index], zone: zone, note: note)
        }

        return nil
    }

    /// Every note whose rect touches `rect`, for the marquee.
    func noteRects(intersecting rect: CGRect) -> [(id: NoteID, rect: CGRect)] {
        let area = rect.standardized

        guard !buckets.isEmpty else { return [] }

        let first = max(0, Int(geometry.seconds(forX: area.minX)))
        let last = min(buckets.count - 1, Int(geometry.seconds(forX: area.maxX)))

        guard first <= last else { return [] }

        var seen = Set<Int>()
        var result: [(id: NoteID, rect: CGRect)] = []

        for bucket in first...last {
            for index in buckets[bucket] where seen.insert(index).inserted {
                if let noteRect = noteRect(notes[index]), noteRect.intersects(area) {
                    result.append((ids[index], noteRect))
                }
            }
        }

        return result
    }

    // MARK: - Drawing

    /// The note a preview turns `note` into, or nil when the preview erases it.
    func previewed(_ note: NoteEvent, id: NoteID) -> NoteEvent? {
        guard let preview, preview.ids.contains(id) else { return note }

        switch preview.kind {
        case let .transform(deltaSeconds, deltaSemitones, _):
            var moved = note
            moved.startTime += deltaSeconds
            moved.endTime += deltaSeconds
            moved.pitch = min(max(moved.pitch + deltaSemitones, 0), 127)

            return moved

        case let .resize(edge, deltaSeconds):
            var resized = note

            switch edge {
            case .start:
                resized.startTime = min(max(resized.startTime + deltaSeconds, 0), resized.endTime - NoteDocument.minimumLength)
            case .end:
                resized.endTime = max(resized.endTime + deltaSeconds, resized.startTime + NoteDocument.minimumLength)
            }

            return resized

        case .erase:
            return nil

        case .draw:
            return note
        }
    }

    /// Whether a transform preview also keeps the original in place.
    var previewDuplicates: Bool {
        if case let .transform(_, _, duplicating)? = preview?.kind { return duplicating }

        return false
    }

    /// The Draw tool's note in progress, if any.
    var drawnPreview: NoteEvent? {
        if case let .draw(note)? = preview?.kind { return note }

        return nil
    }

    /// One note: its fill at its velocity, the onset marker, its syllable (`+Lyrics`), and the
    /// selection outline.
    func drawNote(_ note: NoteEvent, in rect: CGRect, selected: Bool, ctx: CGContext) {
        let k = geometry.scale
        let program = min(max(note.program, 0), NoteEvent.drumProgram)
        // Edit mode: velocity 1…127 → 0.45…1 (§6.5); the Transcribe tab draws every note solid,
        // as it always has. With Show Confidence on, confidence 0…1 → 0.25…1 in both tabs instead,
        // replacing the velocity term rather than multiplying it, so a loud doubtful note is as
        // faint as a quiet one (confidence design §2). Muted wins in all of them.
        let velocityAlpha = showsConfidence
            ? 0.25 + 0.75 * CGFloat(note.confidenceOrSure)
            : grid != nil ? 0.45 + 0.55 * CGFloat(note.velocity - 1) / 126 : 1
        // A highlighted instrument keeps its alpha; the others step back behind it.
        let highlightAlpha: CGFloat = highlightedProgram.map { $0 == program ? 1 : PianoRollView.unhighlightedNoteAlpha } ?? 1
        let alpha = audible[program] ? velocityAlpha * highlightAlpha : PianoRollView.mutedNoteAlpha
        let edgeWidth = PianoRollView.onsetEdgeWidth * k

        ctx.setAlpha(alpha)
        ctx.fillRoundedRect(rect, corner: PianoRollView.noteCorner * k, colours[program])

        // A note-on marker. Without it a run of repeated notes at one pitch reads as one long one.
        if rect.width > 2 * edgeWidth {
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: edgeWidth, height: rect.height), TimelinePalette.noteOnsetEdge)
        }

        // Differentiate Without Colour: a muted note is hatched as well as faded (a11y design §2).
        if !audible[program], Accommodations.shared.differentiateWithoutColour {
            drawHatch(in: rect, ctx: ctx)
        }

        // The curve at full strength over a velocity- or confidence-faded fill, but still behind
        // a highlight and as faint as a muted note (pitch curves design §2). Under 6 px a lane
        // is too thin for a line through it to read as anything but noise.
        if showsPitchCurves, let curve = note.pitchCurve, !curve.isEmpty, rect.height >= 6 * k {
            ctx.setAlpha(audible[program] ? highlightAlpha : PianoRollView.mutedNoteAlpha)
            drawPitchCurve(curve, of: note, in: rect, colour: curveColours[program], ctx: ctx)
        }

        // The words at full strength, as faint as a muted note like the curve (markers and
        // lyrics design §2).
        if let lyric = note.lyric {
            ctx.setAlpha(audible[program] ? 1 : PianoRollView.mutedNoteAlpha)
            drawLyric(lyric, in: rect, ctx: ctx)
        }

        ctx.setAlpha(1)

        guard selected else { return }

        // Stroked on the inside of the fill. A note too narrow for the inset gets a plain outline
        // of its rect; the corner is clamped as `fillRoundedRect` clamps it, or CoreGraphics traps.
        let width = PianoRollView.selectionOutlineWidth * k
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        let outline = inset.width > 0 && inset.height > 0 ? inset : rect
        let corner = min(PianoRollView.noteCorner * k, outline.width / 2, outline.height / 2)

        ctx.setStrokeColor(TimelinePalette.textPrimary)
        ctx.setLineWidth(width)

        if corner > 0 {
            ctx.addPath(CGPath(roundedRect: outline, cornerWidth: corner, cornerHeight: corner, transform: nil))
        } else {
            ctx.addRect(outline)
        }

        ctx.strokePath()
    }

    /// A 1 px polyline through `(x_i, midY − cents_i / 100 × semitone)` (pitch curves design
    /// §2), stepping over frames so it has at most one vertex per point of width, and only over
    /// the part of the note the redraw exposes: a long note at a deep zoom costs what is on
    /// screen. Drawn straight into the context: this runs per note on every repaint.
    private func drawPitchCurve(_ curve: [Float], of note: NoteEvent, in rect: CGRect, colour: CGColor, ctx: CGContext) {
        let pointsPerFrame = geometry.pixelsPerSecond * CGFloat(PitchTracker.frameSeconds)

        guard pointsPerFrame > 0 else { return }

        // A merged note's curve can be shorter than the note; nothing is drawn past either end.
        let last = min(curve.count, max(1, PitchTracker.frameCount(for: note))) - 1
        let clip = ctx.boundingBoxOfClipPath
        let first = max(0, Int(((clip.minX - rect.minX) / pointsPerFrame).rounded(.down)) - 1)
        let end = min(last, Int(((min(clip.maxX, rect.maxX) - rect.minX) / pointsPerFrame).rounded(.up)) + 1)

        guard first <= end else { return }

        let step = max(1, Int((1 / pointsPerFrame).rounded(.up)))
        let semitone = geometry.rowHeight * geometry.scale
        let midY = rect.midY

        func point(_ index: Int) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(index) * pointsPerFrame,
                    y: midY - CGFloat(curve[index]) / 100 * semitone)
        }

        ctx.move(to: point(first))

        var index = first + step

        while index < end {
            ctx.addLine(to: point(index))
            index += step
        }

        ctx.addLine(to: point(end))
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(geometry.scale)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Diagonal lines across a muted note, at full strength over its faded fill.
    private func drawHatch(in rect: CGRect, ctx: CGContext) {
        let k = geometry.scale
        let spacing = 4 * k

        ctx.saveGState()
        ctx.setAlpha(1)
        ctx.clip(to: rect)
        ctx.setStrokeColor(TimelinePalette.textScale)
        ctx.setLineWidth(k)

        var x = rect.minX - rect.height

        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Range

    /// The marked range and, while a region run is in flight, its progress (region design §6.3).
    func setRange(_ range: Range<Double>?, progress: Float?) {
        rangeBand.progress = progress
        RangeBandView.place(rangeBand, range: range, in: self, geometry: geometry)
    }
}
