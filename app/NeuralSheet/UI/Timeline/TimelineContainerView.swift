import AppKit
import NeuralSheetCore
import SwiftUI

/// The whole timeline block (`VisualizationPanel` less its toolbar and status bar): the 46 px
/// gutter-and-keyboard column on the left, and to its right one horizontally scrolling viewport
/// stacking the waveform, the ruler and the piano roll so their time axes can never drift apart.
///
/// Owns the ``TimelineGeometry`` every view reads, watches the model with observation tracking and
/// repaints only what a change touched, and runs a display link that slides the playhead layers
/// and follows the transport without redrawing anything underneath.
///
/// The three bands are not as wide as the content. Each is a window a few viewports wide that
/// slides along with the scroll (``layoutDocument()``), with its bounds origin set to where it
/// sits in the document, so every band keeps drawing, hit-testing and placing its subviews in
/// document coordinates. A band the width of a ten-minute take would be a layer AppKit has to
/// tile, and tiles fill in behind a pan; a window is one layer that pans as a whole.
final class TimelineContainerView: NSView {
    let model: AppModel
    let geometry = TimelineGeometry()

    /// Transcribe or Edit (design §3.4): the waveform's height, what the ruler labels, what the
    /// roll draws and whether it edits. Zoom, scroll and pitch range carry across.
    var mode: TimelineMode = .transcribe {
        didSet {
            guard mode != oldValue else { return }

            let editing = mode == .edit
            geometry.waveformHeight = editing ? TimelineMetrics.waveformHeightEdit : TimelineMetrics.waveformHeight
            geometry.waveformAmpHalfSpan = editing ? TimelineMetrics.waveformAmpHalfSpanEdit : TimelineMetrics.waveformAmpHalfSpan
            gutter.waveformHeight = geometry.waveformHeight
            gutter.isCompact = editing
            waveform.isCompact = editing
            ruler.grid = editing ? model.editor.grid : nil
            roll.grid = editing ? model.editor.grid : nil
            ruler.onRange = editing ? { [weak self] range in self?.model.setRange(range) } : nil
            ruler.snapEnabled = editing && model.editor.snapEnabled
            needsLayout = true
            layoutDocument()
            configureViews()
            placeOverlays()
            waveform.needsDisplay = true
            ruler.needsDisplay = true
            roll.needsDisplay = true
            roll.setFrontier(seconds: frontierSeconds)
            placeRangeBands()
            updatePlayhead()
            syncEditController()
        }
    }

    var scale: CGFloat {
        didSet {
            if scale != oldValue {
                TimelineScroller.scale = scale
                geometry.scale = scale
                needsLayout = true
                configureViews()
            }
        }
    }

    // MARK: - Views

    let gutter = GutterView(frame: .zero)
    let keyboard: KeyboardView
    let scrollView = TimelineScrollView(frame: .zero)
    let document = TimelineDocumentView(frame: .zero)
    let waveform: WaveformView
    let ruler: RulerView
    let roll: PianoRollView

    var ctaHost: OverlayHost<TranscribeCTA>?
    var loadHost: OverlayHost<LoadAudioButton>?

    /// Alive while the timeline is in Edit mode and in a window (`+Editing`).
    var editController: RollEditController?

    // MARK: - Model mirror

    /// What the last sync saw, so a change notification repaints only what moved.
    struct Snapshot: Equatable {
        var state: AppState = .empty
        var isPlaying = false
        var duration: Double = 0
        var zoomLevel: Double = 1
        var verticalZoom: Double = -1
        var goToStartGeneration = 0
        var finalizedThrough: Double = 0
        var mixer = InstrumentMixerState()
        var highlightedProgram: Int?
        var hasModel = false
        var transcribeLabel = ""
        var canTranscribe = false
        var peaksIdentity: ObjectIdentifier?
        var workspace: Workspace = .transcribe
        var grid = TempoGrid()
        var selection: Set<NoteID> = []
        var tool: EditorState.Tool = .select
        var range: Range<Double>?
        var snapEnabled = true
        var regionProgress: Float?
    }

    var snapshot = Snapshot()
    var lastNotes: [NoteEvent] = []
    /// With `lastNotes`: a document replacing a run's placeholders re-identifies unmoved notes.
    var lastNoteIDs: [NoteID] = []
    var hasSynced = false
    var lastLaidOutBounds = CGRect.zero

    /// The decode frontier on show, so a resize can lay its shade out again.
    var frontierSeconds: Double?

    /// The range and the run progress on show, so a resize or a band slide can lay the band out again.
    var rangeOnShow: Range<Double>?
    var rangeProgressOnShow: Float?

    /// How many viewports wide the bands are, and how close to a band's end the viewport may
    /// come before the bands slide to centre on it again.
    static let bandWindowViewports: CGFloat = 3
    static let bandSlideMargin: CGFloat = 0.25

    /// The bands' span in the document, as last laid out.
    var bandWindow = CGRect.zero

    /// True while an observation tracker is waiting for the next write; one at a time.
    var isObservationArmed = false

    /// `VisualizationPanel::mPrevStateForRange`: the state the pitch range last settled on.
    var previousStateForRange: AppState = .empty

    var displayLink: CADisplayLink?
    private let displayLinkProxy = DisplayLinkProxy()

    /// Ticks seen with nothing moving; the link pauses after a few (`Playhead` stopped repainting
    /// too, and a paused link costs nothing).
    var idleTicks = 0

    var clipObserver: NSObjectProtocol?
    var scrollObserver: NSObjectProtocol?

    // MARK: - Init

    init(model: AppModel, scale: CGFloat) {
        self.model = model
        self.scale = scale
        keyboard = KeyboardView(geometry: geometry)
        waveform = WaveformView(geometry: geometry)
        ruler = RulerView(geometry: geometry)
        roll = PianoRollView(geometry: geometry)
        super.init(frame: .zero)

        TimelineScroller.scale = scale
        geometry.scale = scale
        wantsLayer = true
        clipsToBounds = true

        addSubview(gutter)
        addSubview(keyboard)

        document.addSubview(waveform)
        document.addSubview(ruler)
        document.addSubview(roll)
        scrollView.documentView = document
        addSubview(scrollView)

        // The whole timeline is the drop target (§2.2), overlays included.
        registerForDraggedTypes([.fileURL])
        displayLinkProxy.target = self

        waveform.onSeek = { [weak self] seconds in self?.seek(toSeconds: seconds) }
        roll.onSeek = { [weak self] seconds in self?.seek(toSeconds: seconds) }
        ruler.onSeek = { [weak self] seconds in self?.seek(toSeconds: seconds) }
        keyboard.onWheel = { [weak self] event in
            guard let self else { return }

            scrollPitch(with: WheelGesture(event), at: convert(event.locationInWindow, from: nil))
        }

        scrollView.contentView.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clipViewDidResize()
            }
        }

        // Every scroll, so the bands can slide along before the newly exposed part is on screen.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clipViewDidScroll()
            }
        }

        installOverlays()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let clipObserver {
            NotificationCenter.default.removeObserver(clipObserver)
        }

        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TimelinePalette.bgRoot
    }

    // MARK: - Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        displayLink?.invalidate()
        displayLink = nil

        // Off-window the edit controller goes too; back in one it is made again.
        syncEditController()

        guard window != nil else { return }

        configureViews()
        // Arms the observation as it finishes.
        sync()

        // Through a proxy: the link retains its target, and this view must not outlive its window
        // because of it.
        let link = displayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleTicks = 0
    }

    /// Wakes the link for anything that moves the playhead or the view outside the transport:
    /// a seek, a sync, a resize. It pauses itself again once nothing is moving.
    func resumeDisplayLink() {
        idleTicks = 0
        displayLink?.isPaused = false
    }

    /// Click-to-seek from the waveform, the ruler and the roll (§5.1), and from the Edit tab's
    /// roll on empty space.
    func seek(toSeconds seconds: Double) {
        model.seek(toSeconds: seconds)
        resumeDisplayLink()
    }

    // MARK: - Layout

    /// `VisualizationPanel::resized`: the column outside the viewport, the viewport beside it.
    override func layout() {
        super.layout()

        let k = scale
        let columnWidth = TimelineMetrics.gutterWidth * k
        let gutterHeight = geometry.rollY * k

        gutter.frame = CGRect(x: 0, y: 0, width: columnWidth, height: gutterHeight)
        keyboard.frame = CGRect(x: 0, y: gutterHeight, width: columnWidth, height: max(0, bounds.height - gutterHeight))
        scrollView.frame = CGRect(x: columnWidth, y: 0, width: max(0, bounds.width - columnWidth), height: bounds.height)

        // The keyboard's height is what an automatic zoom is fitted against, and what decides how
        // many octaves have to be on screen.
        let keyboardHeight = keyboard.frame.height / k
        let keyboardHeightChanged = geometry.keyboardHeight != keyboardHeight

        if keyboardHeightChanged {
            geometry.keyboardHeight = keyboardHeight
            geometry.settleFirstKey()
        }

        let viewportChanged = layoutDocument()

        // Idempotent past this point: SwiftUI lays the representable out again whenever anything
        // in the window changes, which during playback is every frame.
        guard hasSynced else { return }

        if viewportChanged {
            refreshForAudioLength()
        }

        if keyboardHeightChanged {
            applyVerticalZoom()
        }

        if bounds != lastLaidOutBounds {
            lastLaidOutBounds = bounds
            placeOverlays()
        }

        if viewportChanged || keyboardHeightChanged {
            updatePlayhead()
            resumeDisplayLink()
        }
    }

    /// The scroller appearing or going takes 8 px from the clip view: the bands follow it, and the
    /// zoom floor is re-derived if the width moved too.
    private func clipViewDidResize() {
        if layoutDocument(), hasSynced {
            refreshForAudioLength()
        }
    }

    /// A scroll that has carried the viewport near the end of the bands' window: they slide now,
    /// in the same pass, so nothing blank is ever on screen.
    private func clipViewDidScroll() {
        if desiredBandWindow(contentWidth: geometry.contentWidth) != bandWindow {
            layoutDocument()
        }
    }

    /// The document is as wide as the content and exactly as tall as the clip view, the three
    /// bands stacked inside it over the window the viewport is in. Answers whether the viewport's
    /// width moved, which is what the zoom floor depends on.
    @discardableResult
    func layoutDocument() -> Bool {
        let k = scale
        let viewportWidth = scrollView.contentView.bounds.width
        let height = scrollView.contentView.bounds.height
        let viewportChanged = geometry.viewportWidth != viewportWidth

        if viewportChanged {
            geometry.viewportWidth = viewportWidth
        }

        let width = geometry.contentWidth
        let waveformHeight = geometry.waveformHeight * k
        let rulerHeight = TimelineMetrics.rulerHeight * k
        let rollY = geometry.rollY * k

        let documentFrame = CGRect(x: 0, y: 0, width: width, height: height)
        let documentChanged = document.frame != documentFrame

        if documentChanged {
            document.frame = documentFrame
        }

        let window = desiredBandWindow(contentWidth: width)
        let windowMoved = window != bandWindow
        bandWindow = window

        setFrame(CGRect(x: window.minX, y: 0, width: window.width, height: waveformHeight), of: waveform)
        setFrame(CGRect(x: window.minX, y: waveformHeight, width: window.width, height: rulerHeight), of: ruler)
        setFrame(CGRect(x: window.minX, y: rollY, width: window.width, height: max(0, height - rollY)), of: roll)

        if documentChanged || windowMoved {
            roll.setFrontier(seconds: frontierSeconds)
            placeRangeBands()
        }

        return viewportChanged
    }

    /// Where the bands should span: `bandWindowViewports` wide, centred on the viewport and
    /// inside the content -- or the whole content when that is narrower. The window that is
    /// there is kept while the viewport stays `bandSlideMargin` clear of both its ends, so a
    /// slide (a full repaint of the three bands) happens once per stretch of panning rather than
    /// per wheel event; at an end of the content there is nothing to slide towards.
    private func desiredBandWindow(contentWidth: CGFloat) -> CGRect {
        let clip = scrollView.contentView.bounds
        let viewport = max(clip.width, 1)
        let width = min(contentWidth, (viewport * TimelineContainerView.bandWindowViewports).rounded())
        let margin = viewport * TimelineContainerView.bandSlideMargin
        let current = bandWindow

        if current.width == width, current.maxX <= contentWidth,
           clip.minX >= current.minX + margin || current.minX <= 0,
           clip.maxX <= current.maxX - margin || current.maxX >= contentWidth
        {
            return current
        }

        let x = min(max((clip.midX - width / 2).rounded(), 0), max(0, contentWidth - width))

        return CGRect(x: x, y: 0, width: width, height: 0)
    }

    /// A band's frame is where its window sits in the document, and its bounds origin is the
    /// same x, so the band's own coordinates are document coordinates. Either moving is a whole
    /// new stretch of content: the band repaints.
    private func setFrame(_ frame: CGRect, of view: NSView) {
        let frameChanged = view.frame != frame
        let heightChanged = view.frame.height != frame.height

        if frameChanged {
            view.frame = frame
        }

        // Read after the frame is set: the origin has to match whatever the frame left it at.
        let originChanged = view.bounds.origin.x != frame.minX

        if originChanged {
            view.setBoundsOrigin(CGPoint(x: frame.minX, y: 0))
        }

        if frameChanged || originChanged {
            view.needsDisplay = true
        }

        if heightChanged {
            configureViews()
        }
    }

    /// Re-derives everything that depends on the scale or a band's height.
    func configureViews() {
        waveform.configure()
        ruler.configure()
        roll.configure()
        gutter.scale = scale
        keyboard.needsDisplay = true
        gutter.needsDisplay = true
    }

    /// The band over the roll and the waveform for the range on show, in the Edit tab only.
    func placeRangeBands() {
        let range = mode == .edit ? rangeOnShow : nil

        roll.setRange(range, progress: rangeProgressOnShow)
        waveform.setRange(range, progress: rangeProgressOnShow)
    }

    // MARK: - Overlays

    private func installOverlays() {
        let cta = OverlayHost(rootView: TranscribeCTA(label: model.transcribeLabel, isEnabled: false, scale: scale,
                                                      action: { [weak self] in self?.model.launchTranscription() }))
        cta.isHidden = true
        addSubview(cta)
        ctaHost = cta

        let load = OverlayHost(rootView: LoadAudioButton(scale: scale, action: { [weak self] in
            guard let self, let url = LoadAudioButton.chooseFile() else { return }

            self.model.loadAudio(url: url)
        }))
        load.isHidden = true
        addSubview(load)
        loadHost = load
    }

    /// `VisualizationPanel::_layOutTranscribeButton` and `AudioRegion::resized`: the Transcribe
    /// call-to-action centred on the roll's viewport, the load button centred on the waveform's.
    func placeOverlays() {
        let k = scale
        let state = model.state
        let rollIsIdle = state == .audioLoaded || state == .empty
        let hasModel = !model.installedModels.isEmpty

        if let ctaHost {
            ctaHost.rootView = TranscribeCTA(label: model.transcribeLabel, isEnabled: state == .audioLoaded, scale: k,
                                             action: { [weak self] in self?.model.launchTranscription() })
            ctaHost.isHidden = !(rollIsIdle && hasModel) || mode == .edit

            let viewport = scrollView.frame
            let rollRegion = CGRect(x: viewport.minX, y: viewport.minY + geometry.rollY * k,
                                    width: viewport.width, height: max(0, viewport.height - geometry.rollY * k))

            ctaHost.place(centredIn: rollRegion)
        }

        if let loadHost {
            loadHost.rootView = LoadAudioButton(scale: k, action: { [weak self] in
                guard let self, let url = LoadAudioButton.chooseFile() else { return }

                self.model.loadAudio(url: url)
            })
            loadHost.isHidden = state != .empty || mode == .edit

            let viewport = scrollView.frame
            let waveformRegion = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                                        height: geometry.waveformHeight * k)

            loadHost.place(centredIn: waveformRegion, top: waveformRegion.minY + WaveformView.loadButtonY(scale: k))
        }
    }
}

/// Which tab the timeline is drawn for; the container derives it from the model's workspace.
enum TimelineMode: Equatable {
    case transcribe, edit
}

/// The display link's target: weak on the view, so the link's own retain never keeps the
/// container alive.
final class DisplayLinkProxy: NSObject {
    weak var target: TimelineContainerView?

    @objc func fire(_ link: CADisplayLink) {
        target?.tick()
    }
}

