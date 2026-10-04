import AppKit
import NeuralSheetCore
import QuartzCore

/// What the roll shows: the take and the notes, from the view model.
struct PluginRollContent: Equatable {
    var duration: Double = 0
    var peaks: WaveformPeaks?
    var notes: [NoteEvent] = []
    /// While a run streams: every note ending before this has been reported; right of it is shaded.
    var frontier: Double?
    /// The instruments the strips silence, drawn faded as the Mac's roll draws them.
    var muted: Set<Int> = []

    var isStreaming: Bool { frontier != nil }

    static func == (lhs: PluginRollContent, rhs: PluginRollContent) -> Bool {
        lhs.duration == rhs.duration && lhs.peaks === rhs.peaks && lhs.notes == rhs.notes && lhs.frontier == rhs.frontier
            && lhs.muted == rhs.muted
    }
}

/// The plugin's roll (Audio Unit design §2, "UI"; sub-issue C): the Mac timeline's Edit-tab stack
/// in an `NSView`, read-only. A fixed column on the left -- the gutter corner over the keyboard --
/// and beside it an `NSScrollView` whose document holds the 40 px waveform strip, the ruler and the
/// roll, all reading one ``TimelineGeometry`` and drawn by the shared painters, so they cannot
/// paint differently from the app.
///
/// Time is the scroll view's horizontal offset; pitch is the geometry's `firstKey`, panned by the
/// pixel, as on the Mac (`TimelineContainerView+Interaction`): a wheel over the roll pans both
/// axes, ⌘-wheel and a pinch zoom time, ⌥-wheel and ⌥-pinch zoom pitch. The bands are windows
/// `bandWindowViewports` wide that slide with the scroll, never views the width of the content.
/// The playhead is a layer moved by a display link (`+Playhead`); nothing selects or edits.
final class PluginRollView: NSView {
    let geometry = TimelineGeometry()

    let gutter: PluginGutterBand
    let keyboard: PluginKeyboardBand
    let waveform: PluginWaveformBand
    let ruler: PluginRulerBand
    let roll: PluginRollBand

    let scrollView = PluginScrollView()
    let clip = PluginClipView()
    let document = PluginDocumentView()
    let overlay = PluginOverlayView(frame: .zero)
    let playhead = PlayheadView(drawsTriangle: true)
    let frontierShade = FillView(colour: TimelinePalette.frontierShade)
    let frontierLine = FillView(colour: TimelinePalette.divStrong)

    /// The Mac's numbers: three viewports wide, slid again within a quarter viewport of an end.
    static let bandWindowViewports: CGFloat = 3
    static let bandSlideMargin: CGFloat = 0.25

    private(set) var content = PluginRollContent()

    /// The vertical zoom a gesture set, 0…1; negative fits the notes' octaves (automatic).
    var verticalNorm: Double = -1

    var bandWindow = CGRect.zero
    private var isLayingOut = false

    /// The display link and its quiet frames (`+Playhead`).
    var displayLink: CADisplayLink?
    let displayLinkProxy = PluginDisplayLinkProxy()
    var idleTicks = 0

    /// The transport's position in seconds, read every frame; nil hides the playhead: the host's
    /// position while it plays, the plugin's own transport otherwise (`PluginPlayback`).
    var playheadSeconds: () -> Double? = { 0 }

    override init(frame frameRect: NSRect) {
        gutter = PluginGutterBand(geometry: geometry)
        keyboard = PluginKeyboardBand(geometry: geometry)
        waveform = PluginWaveformBand(geometry: geometry)
        ruler = PluginRulerBand(geometry: geometry)
        roll = PluginRollBand(geometry: geometry)
        super.init(frame: frameRect)

        // The Edit tab's layout, at authored points: the 40 px strip over the ruler and the roll.
        geometry.scale = 1
        geometry.waveformHeight = TimelineMetrics.waveformHeightEdit
        geometry.waveformAmpHalfSpan = TimelineMetrics.waveformAmpHalfSpanEdit
        // Fitted to the take on the first layout (the clamp's lower bound).
        geometry.zoom = 0
        // Time runs left to right in every language.
        userInterfaceLayoutDirection = .leftToRight

        clip.drawsBackground = false
        clip.onScroll = { [weak self] in self?.clipScrolled() }
        scrollView.contentView = clip
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.onWheel = { [weak self] event in self?.scrollWheel(with: event) }
        scrollView.onMagnify = { [weak self] event in self?.magnify(with: event) }

        for band in [waveform, ruler, roll] {
            document.addSubview(band)
        }

        for view in [frontierShade, frontierLine, playhead] as [NSView] {
            overlay.addSubview(view)
        }
        frontierShade.isHidden = true
        frontierLine.isHidden = true
        playhead.isHidden = true

        addSubview(scrollView)
        addSubview(overlay)
        addSubview(gutter)
        addSubview(keyboard)

        displayLinkProxy.target = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.fill(dirtyRect, TimelinePalette.bgRoot)
    }

    // MARK: - Content

    /// Applies what changed since the last update and repaints only the bands it touched.
    func update(_ new: PluginRollContent) {
        let old = content
        content = new

        if new.duration != old.duration || new.peaks !== old.peaks {
            let newTake = new.duration != old.duration
            geometry.duration = new.duration
            waveform.peaks = new.peaks
            waveform.needsDisplay = true

            let canPlay = new.duration > 0
            roll.painter.canPlay = canPlay
            ruler.painter.canPlay = canPlay
            roll.needsDisplay = true
            ruler.needsDisplay = true

            // A new take: fitted to the width, the pitch zoom automatic again.
            if newTake {
                geometry.zoom = 0
                verticalNorm = -1
            }
        }

        if new.notes != old.notes {
            geometry.notesEnd = new.notes.map(\.endTime).max() ?? 0
            roll.painter.notes = new.notes
            // Placeholder ids: nothing hit-tests or selects in the plugin.
            roll.painter.ids = new.notes.indices.map(NoteID.init)
            roll.painter.buckets = RollPainter.secondBuckets(new.notes)
            roll.needsDisplay = true
        }

        if new.muted != old.muted {
            roll.painter.audible = (0...NoteEvent.drumProgram).map { !new.muted.contains($0) }
            roll.needsDisplay = true
        }

        if new.notes != old.notes || new.frontier != old.frontier || new.duration != old.duration {
            applyVerticalZoom()
        }

        setZoom(geometry.zoom, keepingSecondsAtX: nil)
        placeOverlays()
        wakePlayhead()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let k = geometry.scale
        let columnWidth = TimelineMetrics.gutterWidth * k
        let headerHeight = geometry.rollY * k

        gutter.frame = CGRect(x: 0, y: 0, width: columnWidth, height: headerHeight)
        keyboard.frame = CGRect(x: 0, y: headerHeight, width: columnWidth, height: max(0, bounds.height - headerHeight))

        let scrollFrame = CGRect(x: columnWidth, y: 0, width: max(0, bounds.width - columnWidth), height: bounds.height)
        if scrollView.frame != scrollFrame {
            scrollView.frame = scrollFrame
        }
        overlay.frame = scrollFrame

        geometry.keyboardHeight = keyboard.frame.height / k
        geometry.viewportWidth = scrollFrame.width
        gutter.needsDisplay = true
        keyboard.needsDisplay = true

        setZoom(geometry.zoom, keepingSecondsAtX: nil)
        applyVerticalZoom()
        playhead.configure(scale: k, height: bounds.height)
        wakePlayhead()
    }

    /// The document as wide as the timeline, then the bands over the window around the viewport.
    func layoutBands() {
        guard !isLayingOut else { return }

        isLayingOut = true
        defer { isLayingOut = false }

        let k = geometry.scale
        let height = bounds.height
        let size = CGSize(width: geometry.contentWidth, height: height)

        if document.frame.size != size {
            document.setFrameSize(size)
        }

        let window = desiredBandWindow()
        bandWindow = window

        place(waveform, CGRect(x: window.minX, y: 0, width: window.width, height: geometry.waveformHeight * k))
        place(ruler, CGRect(x: window.minX, y: geometry.waveformHeight * k, width: window.width,
                            height: TimelineMetrics.rulerHeight * k))
        place(roll, CGRect(x: window.minX, y: geometry.rollY * k, width: window.width,
                           height: max(0, height - geometry.rollY * k)))
    }

    /// A band's frame is where its window sits in the document and its bounds origin the same x,
    /// so it draws in document coordinates. A new stretch, or a new size, repaints it.
    private func place(_ band: NSView, _ frame: CGRect) {
        let stretchChanged = band.bounds.origin.x != frame.minX || band.bounds.size != frame.size

        if band.frame != frame {
            band.frame = frame
        }

        if band.bounds.origin.x != frame.minX {
            band.setBoundsOrigin(CGPoint(x: frame.minX, y: 0))
        }

        if stretchChanged {
            band.needsDisplay = true
        }
    }

    /// The Mac's `desiredBandWindow`: `bandWindowViewports` wide, centred on the viewport and
    /// inside the content, kept while the viewport stays clear of its ends.
    private func desiredBandWindow() -> CGRect {
        let contentWidth = geometry.contentWidth
        let clipMinX = clip.bounds.minX
        let viewport = max(clip.bounds.width, 1)
        let clipMaxX = clipMinX + viewport
        let width = min(contentWidth, (viewport * Self.bandWindowViewports).rounded())
        let margin = viewport * Self.bandSlideMargin
        let current = bandWindow

        if current.width == width, current.maxX <= contentWidth,
           clipMinX >= current.minX + margin || current.minX <= 0,
           clipMaxX <= current.maxX - margin || current.maxX >= contentWidth
        {
            return current
        }

        let x = min(max((clipMinX + viewport / 2 - width / 2).rounded(), 0), max(0, contentWidth - width))

        return CGRect(x: x, y: 0, width: width, height: 0)
    }

    private func clipScrolled() {
        layoutBands()
        placeOverlays()
        updatePlayhead()
    }

    /// Scrolls time so the viewport's left edge is at document `x`, clamped to the content.
    func scroll(toX x: CGFloat) {
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let target = min(max(0, x), maxX)

        guard abs(clip.bounds.minX - target) > 0.001 else { return }

        clip.scroll(to: CGPoint(x: target, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Repaint

    func repaintAll() {
        for band in [waveform, ruler, roll, keyboard, gutter] as [NSView] {
            band.needsDisplay = true
        }
    }
}
