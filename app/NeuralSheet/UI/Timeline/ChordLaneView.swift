import AppKit
import NeuralSheetCore

/// The chord lane (chord symbols design §2): a 20 px band between the ruler and the roll in the
/// Edit tab, zero high while the list is empty. Each symbol sits 4 px right of a faint tick at its
/// start, clipped at the next one, in the ruler's face a size up. A click on a symbol opens its
/// card, a drag moves it (snapped when the grid snaps), a double-click on empty lane adds one at
/// the nearest beat, and a click on empty lane seeks as the ruler does.
///
/// Like the other bands it draws in document coordinates; the container slides it with them.
final class ChordLaneView: NSView {
    static let height: CGFloat = 20
    static let inset: CGFloat = 4

    let geometry: TimelineGeometry

    /// The list on show, in time order; written by the container's sync.
    var chords: [ChordEvent] = [] {
        didSet { if chords != oldValue { rebuildLabels() } }
    }

    var key: MusicalKey? {
        didSet { if key != oldValue { rebuildLabels() } }
    }

    var grid = TempoGrid()
    var snapEnabled = true

    /// A click on a symbol: its card, at a point in the window.
    var onCard: ((CGPoint, Int) -> Void)?
    /// A double-click on empty lane: a chord at that time; answers its index for the card.
    var onAdd: ((Double) -> Int?)?
    /// A drag let go: the chord at the index to the seconds.
    var onMove: ((Int, Double) -> Void)?
    var onSeek: ((Double) -> Void)?

    let playhead = PlayheadView(drawsTriangle: false)

    /// Each event's text, built when the list or the key changes rather than in `draw`.
    private(set) var labels: [String] = []

    /// VoiceOver's symbols, made when it asks and dropped with the labels or a band slide
    /// (`+Accessibility`).
    var accessibilityChords: [DrawnElement]?

    /// The press on a symbol: which, where, and where the drag has it now.
    private struct Press {
        var index: Int
        var x: CGFloat
        var seconds: Double
        var dragged: Double?
    }

    private var press: Press?

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(playhead)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    func configure() {
        playhead.configure(scale: geometry.scale, height: bounds.height)
        needsDisplay = true
    }

    func setPlayhead(x: CGFloat?) {
        guard let x else {
            playhead.isHidden = true
            return
        }

        playhead.isHidden = false
        playhead.move(toX: x)
    }

    private func rebuildLabels() {
        labels = chords.map { $0.text(in: key) }
        needsDisplay = true
        invalidateAccessibilityChords()
    }

    // MARK: - Drawing

    /// Where event `index` starts on show: the drag's spot for the one being dragged.
    private func seconds(at index: Int) -> Double {
        if let press, press.index == index, let dragged = press.dragged { return dragged }

        return chords[index].seconds
    }

    /// Where the label of event `index` may run to: the next event's start (in time, the drag
    /// included), or the band's end.
    private func labelEnd(at index: Int) -> CGFloat {
        guard press?.dragged != nil else {
            return index + 1 < chords.count ? geometry.x(forSeconds: chords[index + 1].seconds) : bounds.maxX
        }

        let start = seconds(at: index)
        var end = bounds.maxX

        for other in chords.indices where other != index {
            let seconds = seconds(at: other)
            if seconds > start { end = min(end, geometry.x(forSeconds: seconds)) }
        }

        return end
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dirtyRect = rect.intersection(bounds)
        let k = geometry.scale
        let height = bounds.height
        let font = TimelineFonts.chord(k)

        ctx.fill(dirtyRect, TimelinePalette.bgPanel)
        ctx.fill(CGRect(x: dirtyRect.minX, y: height - k, width: dirtyRect.width, height: k), TimelinePalette.divSoft)

        for index in chords.indices where index < labels.count {
            let x = (geometry.x(forSeconds: seconds(at: index)) / k).rounded() * k
            let end = labelEnd(at: index)

            guard end >= dirtyRect.minX, x <= dirtyRect.maxX else { continue }

            let isPressed = press?.index == index
            ctx.fill(CGRect(x: x, y: 0, width: k, height: height), isPressed ? TimelinePalette.tempoStem : TimelinePalette.divTick)

            let box = CGRect(x: x + ChordLaneView.inset * k, y: 0, width: max(0, end - x - ChordLaneView.inset * k), height: height)

            guard box.width > 0 else { continue }

            ctx.saveGState()
            ctx.clip(to: box)
            TimelineText.draw(labels[index], font: font,
                              colour: chords[index].chord == nil ? TimelinePalette.textFaint : TimelinePalette.textBright,
                              in: box, anchor: .centredLeft, context: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Hit testing

    /// The symbol under `x`: its tick and its text, up to the next event.
    private func chordIndex(atX x: CGFloat) -> Int? {
        let k = geometry.scale
        let font = TimelineFonts.chord(k)

        return chords.indices.last { index in
            guard index < labels.count else { return false }

            let start = geometry.x(forSeconds: chords[index].seconds)
            let width = ChordLaneView.inset * 2 * k + TimelineText.width(labels[index], font: font)
            let end = min(start + width, labelEnd(at: index))

            return x >= start - 2 * k && x < max(end, start + 2 * k)
        }
    }

    /// The spot a double-click adds at: the grid line when snapping, else the nearest beat.
    private func addSpot(forX x: CGFloat) -> Double {
        let seconds = max(0, geometry.seconds(forX: x))

        if snapEnabled { return grid.snap(seconds) }

        let segment = grid.segment(atSeconds: seconds)
        let beat = segment.timeSignature.beatLength * 60 / segment.bpm
        let beats = grid.beatLines(from: max(0, seconds - beat), to: seconds + beat)

        return beats.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }?.seconds ?? seconds
    }

    private func dragSpot(_ press: Press, toX x: CGFloat) -> Double {
        let seconds = max(0, press.seconds + geometry.seconds(forX: x) - geometry.seconds(forX: press.x))

        return snapEnabled ? grid.snap(seconds) : seconds
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)

        let point = convert(event.locationInWindow, from: nil)

        if let index = chordIndex(atX: point.x) {
            press = Press(index: index, x: point.x, seconds: chords[index].seconds)
            needsDisplay = true
            return
        }

        if event.clickCount == 2 {
            if let index = onAdd?(addSpot(forX: point.x)) {
                onCard?(event.locationInWindow, index)
            }
        } else {
            onSeek?(geometry.seconds(forX: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = press else { return }

        let x = convert(event.locationInWindow, from: nil).x

        if current.dragged == nil, abs(x - current.x) < RulerView.dragThreshold * geometry.scale { return }

        current.dragged = dragSpot(current, toX: x)
        press = current
        needsDisplay = true
    }

    /// A press that never became a drag is a click: the card. A drag lands where it was let go.
    override func mouseUp(with event: NSEvent) {
        guard let current = press else { return }

        press = nil
        needsDisplay = true

        if let dragged = current.dragged {
            onMove?(current.index, dragged)
        } else {
            onCard?(event.locationInWindow, current.index)
        }
    }
}
