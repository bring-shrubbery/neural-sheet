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
final class TimelineContainerView: NSView {
    let model: AppModel
    let geometry = TimelineGeometry()

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

    // MARK: - Model mirror

    /// What the last sync saw, so a change notification repaints only what moved.
    struct Snapshot: Equatable {
        var state: AppState = .empty
        var duration: Double = 0
        var zoomLevel: Double = 1
        var verticalZoom: Double = -1
        var goToStartGeneration = 0
        var finalizedThrough: Double = 0
        var mixer = InstrumentMixerState()
        var hasModel = false
        var transcribeLabel = ""
        var canTranscribe = false
        var peaksIdentity: ObjectIdentifier?
    }

    var snapshot = Snapshot()
    var lastNotes: [NoteEvent] = []
    var hasSynced = false
    var lastLaidOutBounds = CGRect.zero

    /// The decode frontier on show, so a resize can lay its shade out again.
    var frontierSeconds: Double?
    var syncScheduled = false

    /// `VisualizationPanel::mPrevStateForRange`: the state the pitch range last settled on.
    var previousStateForRange: AppState = .empty

    var displayLink: CADisplayLink?
    var clipObserver: NSObjectProtocol?

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
        document.container = self
        scrollView.documentView = document
        addSubview(scrollView)

        waveform.onSeek = { [weak self] seconds in self?.model.seek(toSeconds: seconds) }
        roll.onSeek = { [weak self] seconds in self?.model.seek(toSeconds: seconds) }
        keyboard.onWheel = { [weak self] event in self?.scrollPitch(with: WheelGesture(event)) }

        scrollView.contentView.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clipViewDidResize()
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

        guard window != nil else { return }

        configureViews()
        // Arms the observation as it finishes.
        sync()

        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tick()
    }

    // MARK: - Layout

    /// `VisualizationPanel::resized`: the column outside the viewport, the viewport beside it.
    override func layout() {
        super.layout()

        let k = scale
        let columnWidth = TimelineMetrics.gutterWidth * k
        let gutterHeight = TimelineMetrics.pianoRollY * k

        gutter.frame = CGRect(x: 0, y: 0, width: columnWidth, height: gutterHeight)
        keyboard.frame = CGRect(x: 0, y: gutterHeight, width: columnWidth, height: max(0, bounds.height - gutterHeight))
        scrollView.frame = CGRect(x: columnWidth, y: 0, width: max(0, bounds.width - columnWidth), height: bounds.height)

        gutter.scale = k

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
        }
    }

    /// The scroller appearing or going takes 8 px from the clip view: the bands follow it, and the
    /// zoom floor is re-derived if the width moved too.
    private func clipViewDidResize() {
        if layoutDocument(), hasSynced {
            refreshForAudioLength()
        }
    }

    /// The document is as wide as the content and exactly as tall as the clip view, the three
    /// bands stacked inside it. Answers whether the viewport's width moved, which is what the zoom
    /// floor depends on.
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
        let waveformHeight = TimelineMetrics.waveformHeight * k
        let rulerHeight = TimelineMetrics.rulerHeight * k
        let rollY = TimelineMetrics.pianoRollY * k

        let documentFrame = CGRect(x: 0, y: 0, width: width, height: height)
        let documentChanged = document.frame != documentFrame

        if documentChanged {
            document.frame = documentFrame
        }

        setFrame(CGRect(x: 0, y: 0, width: width, height: waveformHeight), of: waveform)
        setFrame(CGRect(x: 0, y: waveformHeight, width: width, height: rulerHeight), of: ruler)
        setFrame(CGRect(x: 0, y: rollY, width: width, height: max(0, height - rollY)), of: roll)

        if documentChanged {
            roll.setFrontier(seconds: frontierSeconds)
        }

        return viewportChanged
    }

    private func setFrame(_ frame: CGRect, of view: NSView) {
        guard view.frame != frame else { return }

        let heightChanged = view.frame.height != frame.height
        view.frame = frame

        if heightChanged {
            configureViews()
        }
    }

    /// Re-derives everything that depends on the scale or a band's height.
    func configureViews() {
        waveform.configure()
        ruler.configure()
        roll.configure()
        keyboard.needsDisplay = true
        gutter.needsDisplay = true
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
            ctaHost.isHidden = !(rollIsIdle && hasModel)

            let viewport = scrollView.frame
            let rollRegion = CGRect(x: viewport.minX, y: viewport.minY + TimelineMetrics.pianoRollY * k,
                                    width: viewport.width, height: max(0, viewport.height - TimelineMetrics.pianoRollY * k))

            ctaHost.place(centredIn: rollRegion)
        }

        if let loadHost {
            loadHost.rootView = LoadAudioButton(scale: k, action: { [weak self] in
                guard let self, let url = LoadAudioButton.chooseFile() else { return }

                self.model.loadAudio(url: url)
            })
            loadHost.isHidden = state != .empty

            let viewport = scrollView.frame
            let waveformRegion = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                                        height: TimelineMetrics.waveformHeight * k)

            loadHost.place(centredIn: waveformRegion, top: waveformRegion.minY + WaveformView.loadButtonY(scale: k))
        }
    }
}
