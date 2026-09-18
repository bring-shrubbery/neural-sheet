import AppKit
import NeuralSheetCore

/// The piano roll (`PianoRoll`): one lane per semitone on show, the notes in their instruments'
/// colours, the wash left of the playhead and the shade past the decode frontier.
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

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    let playhead = PlayheadView(drawsTriangle: false)
    let wash = FillView(colour: TimelinePalette.accentWashRoll)
    let frontierShade = FillView(colour: TimelinePalette.frontierShade)
    let frontierLine = FillView(colour: TimelinePalette.divStrong)

    private var notes: [NoteEvent] = []

    /// `buckets[s]` holds the indices of every note drawn over second `s`, in note order.
    private var buckets: [[Int]] = []

    /// Per program: whether it is heard, and the colour it draws in.
    private var audible = [Bool](repeating: true, count: NoteEvent.drumProgram + 1)
    private var colours: [CGColor] = []

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

        // The order `PianoRoll::paint` draws them in, over the lanes and the notes.
        addSubview(wash)
        addSubview(frontierShade)
        addSubview(frontierLine)
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
    func setNotes(_ newNotes: [NoteEvent]) {
        notes = newNotes

        let seconds = Int((newNotes.map { PianoRollView.drawnEnd(of: $0) }.max() ?? 0).rounded(.up)) + 1
        var newBuckets = [[Int]](repeating: [], count: max(1, seconds))

        for (index, note) in newNotes.enumerated() {
            let first = max(0, Int(note.startTime))
            let last = max(first, Int(PianoRollView.drawnEnd(of: note)))

            for bucket in first...min(last, newBuckets.count - 1) {
                newBuckets[bucket].append(index)
            }
        }

        buckets = newBuckets
    }

    var hasNotes: Bool { !notes.isEmpty }

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

    private static func drawnEnd(of note: NoteEvent) -> Double {
        note.isDrum ? max(note.endTime, note.startTime + drumMinDrawnSeconds) : note.endTime
    }

    // MARK: - Overlays

    func configure() {
        playhead.configure(scale: geometry.scale, height: bounds.height)
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
            // grid the design deliberately does without.
            if note % 12 == 0 {
                ctx.fill(CGRect(x: dirtyRect.minX, y: lane.y + lane.height - k, width: dirtyRect.width, height: k),
                         empty ? TimelinePalette.divOctaveEmpty : TimelinePalette.divOctave)
            }
        }
    }

    /// `PianoRoll::_drawNotes`, over the notes whose seconds cross the exposed sliver.
    private func drawNotes(_ ctx: CGContext, in dirtyRect: CGRect) {
        guard !notes.isEmpty, !buckets.isEmpty else { return }

        let k = geometry.scale
        let range = geometry.pitchRange
        let height = bounds.height
        let corner = PianoRollView.noteCorner * k
        let edgeWidth = PianoRollView.onsetEdgeWidth * k

        let fromSeconds = max(0, geometry.seconds(forX: dirtyRect.minX))
        let toSeconds = geometry.seconds(forX: dirtyRect.maxX)
        let firstBucket = min(Int(fromSeconds), buckets.count - 1)
        let lastBucket = min(Int(toSeconds), buckets.count - 1)

        guard firstBucket <= lastBucket else { return }

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

        for index in indices {
            let note = notes[index]

            // The range always covers the whole transcription, so this only skips a note in the
            // window between it arriving and the range being told about it.
            guard note.pitch >= range.low, note.pitch <= range.high else { continue }

            let lane = geometry.lane(forPitch: note.pitch)

            if lane.y < 0 || lane.height >= height {
                continue
            }

            let x = geometry.x(forSeconds: note.startTime)
            let width = max(1 * k, geometry.x(forSeconds: PianoRollView.drawnEnd(of: note)) - x - 1 * k)
            let noteRect = CGRect(x: x, y: lane.y, width: width, height: lane.height)

            guard noteRect.maxX >= dirtyRect.minX, noteRect.minX <= dirtyRect.maxX else { continue }

            let program = min(max(note.program, 0), NoteEvent.drumProgram)
            let alpha = audible[program] ? 1 : PianoRollView.mutedNoteAlpha

            ctx.setAlpha(alpha)
            ctx.fillRoundedRect(noteRect, corner: corner, colours[program])

            // A note-on marker. Without it a run of repeated notes at one pitch reads as one long one.
            if width > 2 * edgeWidth {
                ctx.fill(CGRect(x: x, y: lane.y, width: edgeWidth, height: lane.height), TimelinePalette.noteOnsetEdge)
            }

            ctx.setAlpha(1)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(geometry.seconds(forX: x))
    }
}
