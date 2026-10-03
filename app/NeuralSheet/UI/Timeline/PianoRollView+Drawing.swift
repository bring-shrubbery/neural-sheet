#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import NeuralSheetCore

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

/// A compared version's notes and their second buckets (versions design §2). The notes are the
/// model's own array, shared rather than copied, and the buckets are built once when the
/// comparison changes, so a repaint touches only the ghosts that cross the sliver.
struct GhostNotes {
    var notes: [NoteEvent] = []
    var buckets: [[Int]] = []
}

/// What the piano roll draws and how (`PianoRoll::paint`), apart from any view: the lanes, the
/// grid, the ghosts, the notes with their onset markers, curves, syllables and selection outline,
/// and a drag's preview. ``PianoRollView`` on the Mac and the iPhone and iPad app's roll both hold
/// one and call ``draw(_:in:bounds:)`` from their own draw (iOS app design §2), so the two can
/// never paint differently.
///
/// Notes are bucketed by second so a repaint of one sliver — the playhead moving, a chunk
/// landing — touches only the notes that cross it, never the whole transcription.
struct RollPainter {
    let geometry: TimelineGeometry

    /// Nothing is drawn unless the transport can play (`PianoRoll::paint`).
    var canPlay = false

    /// The tempo grid drawn over the lanes, in the Edit tab; nil draws none.
    var grid: TempoGrid?

    /// The project's key, whose scale colours the lanes (key design §5); nil colours them by key
    /// colour.
    var key: MusicalKey?

    /// View → Show Confidence (confidence design §2): notes shade by how sure the model was.
    var showsConfidence = false

    /// View → Show Pitch Curves (pitch curves design §2): a tracked note's curve through it.
    var showsPitchCurves = true

    var notes: [NoteEvent] = []
    /// `ids[i]` identifies `notes[i]`; placeholder ids while a run streams (nothing hit-tests them).
    var ids: [NoteID] = []

    /// `buckets[s]` holds the indices of every note drawn over second `s`, in note order.
    var buckets: [[Int]] = []

    /// Per program: whether it is heard, and the colour it draws in.
    var audible = [Bool](repeating: true, count: NoteEvent.drumProgram + 1)
    let colours: [CGColor]
    /// Per program: its colour lightened 30 % toward white, what a pitch curve is stroked in so
    /// it reads over its own note's fill.
    let curveColours: [CGColor]

    /// The instrument a strip click singled out: every other instrument fades while it is set.
    var highlightedProgram: Int?

    /// Design §6.5: the selection's outline, a drag's preview, and the indices the preview names.
    var selection: Set<NoteID> = []
    var preview: DragPreview?
    var previewIndices: [Int] = []

    /// The compared version's notes, drawn hollow under the notes (versions design §2).
    var ghosts = GhostNotes()

    /// How far a drum hit is widened for drawing (`DRUM_MIN_DRAWN_SECONDS`).
    static let drumMinDrawnSeconds = 0.1
    static let mutedNoteAlpha: CGFloat = 0.16
    /// What the other instruments fade to while one is highlighted: still legible, clearly behind.
    static let unhighlightedNoteAlpha: CGFloat = 0.35
    static let noteCorner: CGFloat = 2
    static let onsetEdgeWidth: CGFloat = 2
    static let selectionOutlineWidth: CGFloat = 1.5
    static let ghostAlpha: CGFloat = 0.5
    static let lyricInset: CGFloat = 3
    static let lyricMinHeight: CGFloat = 9

    init(geometry: TimelineGeometry) {
        self.geometry = geometry

        let colours = (0...NoteEvent.drumProgram).map { program in
            TimelinePalette.cg(Instruments.info(forProgram: program).colour, alpha: 1)
        }
        self.colours = colours
        curveColours = colours.map(RollPainter.lightened)
    }

    /// A colour 30 % of the way to white: `NSColor.blended(withFraction:of:)` on the Mac, the
    /// same per-channel blend in sRGB elsewhere.
    private nonisolated static func lightened(_ colour: CGColor) -> CGColor {
        #if os(macOS)
        return NSColor(cgColor: colour)?.blended(withFraction: 0.3, of: .white)?.cgColor ?? colour
        #else
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = colour.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 4
        else { return colour }

        return CGColor(srgbRed: c[0] + (1 - c[0]) * 0.3, green: c[1] + (1 - c[1]) * 0.3,
                       blue: c[2] + (1 - c[2]) * 0.3, alpha: c[3])
        #endif
    }

    var hasNotes: Bool { !notes.isEmpty }

    static func drawnEnd(of note: NoteEvent) -> Double {
        note.isDrum ? max(note.endTime, note.startTime + drumMinDrawnSeconds) : note.endTime
    }

    // MARK: - Drawing

    /// The background, then the lanes and the notes over `dirtyRect`, in the band's own
    /// coordinates (document x, y down from the roll's top).
    func draw(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect) {
        ctx.fill(dirtyRect, TimelinePalette.bgRoot)

        guard canPlay else { return }

        drawLanes(ctx, in: dirtyRect)
        drawNotes(ctx, in: dirtyRect, height: bounds.height)
    }

    /// `PianoRoll::_drawLanes`: `laneWhite` / `laneBlack` by key colour, held back to 55 % while
    /// there is nothing on them, and a 1 px `divOctave` separator under every C. With a key set
    /// (key design §5) the lanes go by the scale instead: in-scale light, out-of-scale dark, the
    /// tonic's washed with the accent.
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

            let white = key.map { $0.contains(pitch: note) } ?? !KeyboardLayout.isBlack(note)
            let colour = empty
                ? (white ? TimelinePalette.laneWhiteEmpty : TimelinePalette.laneBlackEmpty)
                : (white ? TimelinePalette.laneWhite : TimelinePalette.laneBlack)

            ctx.fill(laneRect, colour)

            if let key, key.isTonic(pitch: note) {
                ctx.fill(laneRect, TimelinePalette.laneTonic)
            }

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
    /// they crowd, judged by the densest segment in view (tempo map design §2).
    private func drawGrid(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect) {
        let k = geometry.scale
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        // One authored pixel of slack on the left: a line's x is rounded, so one just outside the
        // sliver can land inside it.
        let from = max(0, geometry.seconds(forX: dirtyRect.minX - k))
        let to = geometry.seconds(forX: dirtyRect.maxX)
        let visible = grid.segments(from: from, to: to)
        let fastest = visible.map(\.bpm).max() ?? grid.bpm
        let divisionPixels = grid.division.beats * 60 / fastest * pixelsPerSecond
        let beatPixels = (visible.map { $0.timeSignature.beatLength * 60 / $0.bpm }.min() ?? 0) * pixelsPerSecond
        let drawDivisions = divisionPixels >= 6
        let drawBeats = beatPixels >= 3
        // A division coarser than a beat still shows the meter's beats.
        let lines = drawDivisions && grid.division.beats < 1
            ? grid.lines(from: from, to: to)
            : grid.beatLines(from: from, to: to)

        for line in lines {
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
    private func drawNotes(_ ctx: CGContext, in dirtyRect: CGRect, height: CGFloat) {
        // Under the notes, so a note the version shares covers its ghost (versions design §2).
        drawGhosts(ctx, in: dirtyRect, height: height)

        let previewSet = Set(previewIndices)

        for index in indices(crossing: dirtyRect, of: notes, buckets: buckets) where !previewSet.contains(index) {
            let note = notes[index]

            guard let rect = noteRect(note, height: height), rect.maxX >= dirtyRect.minX, rect.minX <= dirtyRect.maxX
            else { continue }

            drawNote(note, in: rect, selected: selection.contains(ids[index]), ctx: ctx)
        }

        // The preview's notes, wherever they land now. Not clipped to the sliver: the preview
        // invalidates the whole visible rect, and a moved note has to leave where it was.
        for index in previewIndices {
            let original = notes[index]

            if previewDuplicates, let rect = noteRect(original, height: height) {
                drawNote(original, in: rect, selected: false, ctx: ctx)
            }

            guard let shown = previewed(original, id: ids[index]), let rect = noteRect(shown, height: height) else { continue }

            drawNote(shown, in: rect, selected: true, ctx: ctx)
        }

        if let drawn = drawnPreview, let rect = noteRect(drawn, height: height) {
            drawNote(drawn, in: rect, selected: true, ctx: ctx)
        }
    }

    /// The ghosts crossing the exposed sliver, windowed by their buckets like the notes: each
    /// stroked 1 px in the instrument's colour at half alpha with no fill (versions design §2).
    private func drawGhosts(_ ctx: CGContext, in dirtyRect: CGRect, height: CGFloat) {
        guard !ghosts.notes.isEmpty else { return }

        let k = geometry.scale
        let lineWidth = 1 * k

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setAlpha(RollPainter.ghostAlpha)

        for index in indices(crossing: dirtyRect, of: ghosts.notes, buckets: ghosts.buckets) {
            let note = ghosts.notes[index]

            guard let rect = noteRect(note, height: height), rect.maxX >= dirtyRect.minX, rect.minX <= dirtyRect.maxX
            else { continue }

            let program = min(max(note.program, 0), NoteEvent.drumProgram)
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let corner = min(RollPainter.noteCorner * k, inset.width / 2, inset.height / 2)

            ctx.setStrokeColor(colours[program])
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, corner), cornerHeight: max(0, corner), transform: nil))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Geometry

    /// The rect a note is drawn in, or nil when its pitch is off the range; `height` is the
    /// band's.
    func noteRect(_ note: NoteEvent, height: CGFloat) -> CGRect? {
        let k = geometry.scale
        let range = geometry.pitchRange

        // The range always covers the whole transcription, so this only skips a note in the
        // window between it arriving and the range being told about it.
        guard note.pitch >= range.low, note.pitch <= range.high else { return nil }

        let lane = geometry.lane(forPitch: note.pitch)

        guard lane.y >= 0, lane.height < height else { return nil }

        let x = geometry.x(forSeconds: note.startTime)
        let width = max(1 * k, geometry.x(forSeconds: RollPainter.drawnEnd(of: note)) - x - 1 * k)

        return CGRect(x: x, y: lane.y, width: width, height: lane.height)
    }

    /// `result[s]` holds the indices of every note of `notes` drawn over second `s`, in note
    /// order: the notes' and the ghosts' buckets alike.
    static func secondBuckets(_ notes: [NoteEvent]) -> [[Int]] {
        let seconds = Int((notes.map { RollPainter.drawnEnd(of: $0) }.max() ?? 0).rounded(.up)) + 1
        var newBuckets = [[Int]](repeating: [], count: max(1, seconds))

        for (index, note) in notes.enumerated() {
            let first = max(0, Int(note.startTime))
            let last = max(first, Int(RollPainter.drawnEnd(of: note)))

            for bucket in first...min(last, newBuckets.count - 1) {
                newBuckets[bucket].append(index)
            }
        }

        return newBuckets
    }

    /// The indices of the notes whose seconds cross `dirtyRect`, for any notes and their
    /// ``secondBuckets(_:)``: the ghosts' too.
    func indices(crossing dirtyRect: CGRect, of notes: [NoteEvent], buckets: [[Int]]) -> [Int] {
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

    // MARK: - Preview

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

    /// The indices of the notes the preview names, so they can be drawn wherever they land
    /// rather than only from the buckets of where they were.
    mutating func refreshPreviewIndices() {
        guard let preview else {
            previewIndices = []
            return
        }

        previewIndices = ids.indices.filter { preview.ids.contains(ids[$0]) }
    }

    // MARK: - One note

    /// One note: its fill at its velocity, the onset marker, its syllable, and the selection
    /// outline.
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
        let highlightAlpha: CGFloat = highlightedProgram.map { $0 == program ? 1 : RollPainter.unhighlightedNoteAlpha } ?? 1
        let alpha = audible[program] ? velocityAlpha * highlightAlpha : RollPainter.mutedNoteAlpha
        let edgeWidth = RollPainter.onsetEdgeWidth * k

        ctx.setAlpha(alpha)
        ctx.fillRoundedRect(rect, corner: RollPainter.noteCorner * k, colours[program])

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
            ctx.setAlpha(audible[program] ? highlightAlpha : RollPainter.mutedNoteAlpha)
            drawPitchCurve(curve, of: note, in: rect, colour: curveColours[program], ctx: ctx)
        }

        // The words at full strength, as faint as a muted note like the curve (markers and
        // lyrics design §2).
        if let lyric = note.lyric {
            ctx.setAlpha(audible[program] ? 1 : RollPainter.mutedNoteAlpha)
            drawLyric(lyric, in: rect, ctx: ctx)
        }

        ctx.setAlpha(1)

        guard selected else { return }

        // Stroked on the inside of the fill. A note too narrow for the inset gets a plain outline
        // of its rect; the corner is clamped as `fillRoundedRect` clamps it, or CoreGraphics traps.
        let width = RollPainter.selectionOutlineWidth * k
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        let outline = inset.width > 0 && inset.height > 0 ? inset : rect
        let corner = min(RollPainter.noteCorner * k, outline.width / 2, outline.height / 2)

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

    /// A note's syllable written inside it (markers and lyrics design §2; issue #18, requirement
    /// 12): in the roll's small face, 3 px in from the onset, centred in the lane, in the ink the
    /// selection outline uses, and only where the note is wide and tall enough to hold it whole;
    /// a note too small shows nothing rather than a clipped fragment. Called on every repaint, so
    /// the width is measured once per text and scale and kept (``LyricWidths``).
    private func drawLyric(_ lyric: Lyric, in rect: CGRect, ctx: CGContext) {
        let k = geometry.scale

        guard rect.height >= RollPainter.lyricMinHeight * k, !lyric.text.isEmpty else { return }

        let font = TimelineFonts.scaleLabel(k)
        let inset = RollPainter.lyricInset * k

        guard rect.width >= LyricWidths.width(of: lyric.text, font: font, scale: k) + 2 * inset else { return }

        TimelineText.draw(lyric.text, font: font, colour: TimelinePalette.textPrimary,
                          in: CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height),
                          anchor: .centredLeft, context: ctx)
    }
}

/// The measured widths of the syllables the roll has drawn, keyed by scale and text: a repaint
/// draws every visible note, and a long sung line would otherwise lay out the same words again
/// on every frame of a scroll. An `NSCache`, so memory pressure can empty it.
@MainActor enum LyricWidths {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        return cache
    }()

    static func width(of text: String, font: CTFont, scale: CGFloat) -> CGFloat {
        let key = "\(scale)|\(text)" as NSString

        if let cached = cache.object(forKey: key) { return CGFloat(cached.doubleValue) }

        let width = TimelineText.width(text, font: font)
        cache.setObject(NSNumber(value: Double(width)), forKey: key)

        return width
    }
}
