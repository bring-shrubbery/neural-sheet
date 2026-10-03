import AppKit
import NeuralSheetCore

/// The 22 px time ruler (`TimeRuler`): absolute seconds only, a 1 px tick per division and an
/// `m:ss` label 6 px to its right. In the Edit tab it reads bars and beats off the tempo grid
/// instead (design §6.4). Nothing is drawn unless the transport can play. In both tabs a drag
/// marks a range; a click still seeks (region design §6.2); the tempo map's changes are flags
/// (`RulerView+TempoMarkers.swift`), and so are the section markers (`RulerView+Markers.swift`).
final class RulerView: NSView {
    let geometry: TimelineGeometry

    /// The drawing's state and the drawing itself (`RulerView+Drawing.swift`), shared with the
    /// iPhone and iPad app.
    var painter: RulerPainter

    var canPlay: Bool {
        get { painter.canPlay }
        set {
            if newValue != painter.canPlay {
                painter.canPlay = newValue
                needsDisplay = true
            }
        }
    }

    /// Bars and beats instead of seconds, in the Edit tab; nil labels seconds.
    var grid: TempoGrid? {
        get { painter.grid }
        set { painter.grid = newValue }
    }

    /// The tempo map whose changes are flagged, in both tabs (tempo map design §4).
    var tempoMap: TempoGrid? {
        get { painter.tempoMap }
        set { painter.tempoMap = newValue }
    }

    /// A right-click, or a click on a tempo flag: the ruler's card for what is under the
    /// pointer, at a point in the window.
    var onTempoCard: ((CGPoint, RulerCardTarget) -> Void)?

    /// The section markers flagged along the bottom of the ruler, in both tabs (markers and
    /// lyrics design §2).
    var markers: [Marker] {
        get { painter.markers }
        set {
            if newValue != painter.markers {
                painter.markers = newValue
                needsDisplay = true
            }
        }
    }

    /// A drag on a marker's flag moves it; a double-click marks its section.
    var onMoveMarker: ((UUID, Double) -> Void)?
    var onMarkRange: ((UUID) -> Void)?

    /// The marker flag being pressed, and whether the press has become a drag.
    var markerPress: MarkerPress?

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    /// A drag marks a range for Re-transcribe (region design §6.2), in both tabs. Without it the
    /// press is a seek as it always was.
    var onRange: ((Range<Double>) -> Void)?

    /// Whether the range's ends snap to the grid; the container mirrors the editor's setting.
    var snapEnabled = false

    /// The press's x, and whether it has travelled far enough to be a drag.
    private var pressX: CGFloat?
    private var isDragging = false

    /// Authored pixels a press may wander and still be a click.
    static let dragThreshold: CGFloat = 3

    /// The playhead VoiceOver reads as the ruler's value (`+Accessibility`); the container's.
    var accessibilityPlayhead: (() -> Double)?
    /// The flags' elements, kept while the flags stay the same (`+Accessibility`).
    var accessibilityFlags: (flags: [String], elements: [DrawnElement])?

    let playhead = PlayheadView(drawsTriangle: false)

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        painter = RulerPainter(geometry: geometry)
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
    }

    func setPlayhead(x: CGFloat?) {
        guard let x else {
            playhead.isHidden = true
            return
        }

        playhead.isHidden = false
        playhead.move(toX: x)
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        painter.draw(ctx, in: rect.intersection(bounds), bounds: bounds)
    }

    // MARK: - Mouse

    /// The first click on the timeline while the note card is key is a click, not a focus change.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A field that had the keyboard commits and lets go, so Space is the transport's again.
        window?.makeFirstResponder(nil)

        let point = convert(event.locationInWindow, from: nil)
        let x = point.x

        // A section marker's flag is taken hold of: a drag moves it, a double-click marks its
        // section, and a plain click does nothing, not even seek.
        if beginMarkerPress(event, at: point) { return }

        // A tempo change's flag is its marker: the click opens its card rather than seeking.
        if let flag = tempoFlag(at: point), let onTempoCard {
            onTempoCard(event.locationInWindow, RulerCardTarget(bar: flag.bar, seconds: geometry.seconds(forX: flag.frame.minX)))
            return
        }

        guard onRange != nil else {
            // With nobody to mark a range for, the press is the seek, as it always was.
            onSeek?(geometry.seconds(forX: x))
            return
        }

        pressX = x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if dragMarker(event) { return }

        guard let pressX, onRange != nil else { return }

        let x = convert(event.locationInWindow, from: nil).x

        if !isDragging, abs(x - pressX) < RulerView.dragThreshold * geometry.scale { return }

        isDragging = true
        onRange?(range(from: pressX, to: x))
    }

    /// A press that never became a drag is the click it always was: a seek.
    override func mouseUp(with event: NSEvent) {
        if endMarkerPress() { return }

        defer {
            pressX = nil
            isDragging = false
        }

        guard let pressX else { return }

        if isDragging {
            onRange?(range(from: pressX, to: convert(event.locationInWindow, from: nil).x))
        } else {
            onSeek?(geometry.seconds(forX: pressX))
        }
    }

    /// The seconds between two x's, in order, both ends snapped when the grid snaps, clamped to
    /// the take. The model refuses a sliver, so a drag that snaps to one line clears the range.
    private func range(from a: CGFloat, to b: CGFloat) -> Range<Double> {
        var lower = geometry.seconds(forX: min(a, b))
        var upper = geometry.seconds(forX: max(a, b))

        if snapEnabled, let grid {
            lower = grid.snap(lower)
            upper = grid.snap(upper)
        }

        lower = min(max(lower, 0), geometry.duration)
        upper = min(max(upper, lower), geometry.duration)

        return lower ..< upper
    }
}

/// The 46 px column beside the waveform and the ruler (`TimelineGutter`): the amplitude scale,
/// each label centred on the exact y its amplitude maps to. The ruler's share is deliberately empty.
/// Beside the Edit tab's strip there is no room for the scale, so only the rules are drawn.
final class GutterView: NSView {
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The waveform band's height in authored pixels; the container keeps it in step with the
    /// geometry, which this view does not hold.
    var waveformHeight: CGFloat = TimelineMetrics.waveformHeight {
        didSet {
            if waveformHeight != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Beside the Edit tab's strip: no amplitude labels.
    var isCompact = false {
        didSet {
            if isCompact != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        GutterPainter.draw(ctx, in: rect, bounds: bounds, scale: scale, waveformHeight: waveformHeight, isCompact: isCompact)
    }
}
