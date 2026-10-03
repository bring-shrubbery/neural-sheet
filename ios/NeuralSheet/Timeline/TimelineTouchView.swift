import NeuralSheetCore
import QuartzCore
import UIKit

/// The touch timeline (iOS app design §2, sub-issue E): the Mac's `TimelineContainerView` stack
/// over UIKit. A fixed column on the left -- the gutter corner over the keyboard -- and beside it
/// one `UIScrollView` whose content stacks the waveform strip, the ruler, the chord lane while
/// there are chords, and the roll, all reading one ``TimelineGeometry`` and drawing with the
/// Mac's painters, so their time axes can never drift apart.
///
/// The scroll view pans both axes with one finger. Time is its horizontal offset, as on the Mac;
/// pitch is its vertical offset turned into the geometry's `firstKey` (``pitchScrollExtent``),
/// with the bands pinned to the top of the viewport, so a pan over the roll moves the lanes and
/// the keys together by the point, as a wheel does on the Mac.
///
/// The bands are windows `bandWindowViewports` viewports wide that slide with the scroll
/// (``layoutBands()``), never layers the width of the content. The playhead copies are layers
/// moved by a display link at the screen's rate reading the engine (`+Playhead`).
final class TimelineTouchView: UIView, UIScrollViewDelegate {
    let model: MobileModel
    let geometry = TimelineGeometry()

    let gutter: GutterBandView
    let keyboard: KeyboardBandView
    let scrollView = UIScrollView()
    let waveform: WaveformBandView
    let ruler: RulerBandView
    let chordLane: ChordLaneBandView
    let roll: RollBandView

    /// How many viewports wide the bands are, and how close to a band's end the viewport may come
    /// before they slide to centre on it again (the Mac's numbers).
    static let bandWindowViewports: CGFloat = 3
    static let bandSlideMargin: CGFloat = 0.25

    /// The bands' span in the document, as last laid out.
    var bandWindow = CGRect.zero

    /// What the last sync applied (`+Sync`).
    var snapshot = Snapshot()
    var isObservationArmed = false
    var hasSynced = false

    /// Set while the timeline moves the scroll view itself, so the delegate does not read the move
    /// back as a pan.
    var isSettingOffset = false

    /// The gestures' state (`+Gestures`).
    var pinch = PinchState()
    var rulerPressX: CGFloat?

    /// The display link and how many quiet frames it has seen (`+Playhead`).
    var displayLink: CADisplayLink?
    var idleTicks = 0
    var accommodationsObserver: NSObjectProtocol?

    init(model: MobileModel) {
        self.model = model
        gutter = GutterBandView(geometry: geometry)
        keyboard = KeyboardBandView(geometry: geometry)
        waveform = WaveformBandView(geometry: geometry)
        ruler = RulerBandView(geometry: geometry)
        chordLane = ChordLaneBandView(geometry: geometry)
        roll = RollBandView(geometry: geometry)
        super.init(frame: .zero)

        backgroundColor = UIColor(cgColor: TimelinePalette.bgRoot)
        clipsToBounds = true
        // Time runs left to right in every language (localization design §2).
        semanticContentAttribute = .forceLeftToRight

        // The Edit tab's layout: there is one roll on iOS, and selection is always on.
        geometry.scale = 1
        geometry.waveformHeight = TimelineMetrics.waveformHeightEdit
        geometry.waveformAmpHalfSpan = TimelineMetrics.waveformAmpHalfSpanEdit

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .normal
        scrollView.backgroundColor = UIColor(cgColor: TimelinePalette.bgRoot)

        for band in [waveform, ruler, chordLane, roll] as [UIView] {
            scrollView.addSubview(band)
        }

        addSubview(scrollView)
        addSubview(gutter)
        addSubview(keyboard)

        installGestures()

        accommodationsObserver = NotificationCenter.default.addObserver(
            forName: Accommodations.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repaintAll() }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let accommodationsObserver {
            NotificationCenter.default.removeObserver(accommodationsObserver)
        }
    }

    // MARK: - Window

    override func didMoveToWindow() {
        super.didMoveToWindow()

        displayLink?.invalidate()
        displayLink = nil

        guard window != nil else { return }

        sync()
        startDisplayLink()
    }

    // MARK: - Layout

    /// The column outside the scroll view, the scroll view beside it; the keyboard's height is
    /// what the vertical fit is measured against, as on the Mac.
    override func layoutSubviews() {
        super.layoutSubviews()

        let k = geometry.scale
        let columnWidth = TimelineMetrics.gutterWidth * k
        let headerHeight = geometry.rollY * k

        gutter.frame = CGRect(x: 0, y: 0, width: columnWidth, height: headerHeight)
        keyboard.frame = CGRect(x: 0, y: headerHeight, width: columnWidth, height: max(0, bounds.height - headerHeight))

        let scrollFrame = CGRect(x: columnWidth, y: 0, width: max(0, bounds.width - columnWidth), height: bounds.height)

        if scrollView.frame != scrollFrame {
            scrollView.frame = scrollFrame
        }

        let keyboardHeight = keyboard.frame.height / k
        let viewportWidth = scrollView.bounds.width
        let changed = geometry.keyboardHeight != keyboardHeight || geometry.viewportWidth != viewportWidth

        geometry.keyboardHeight = keyboardHeight
        geometry.viewportWidth = viewportWidth

        guard hasSynced, changed else {
            layoutBands()
            return
        }

        setZoom(geometry.zoom, keepingSecondsAtX: nil)
        applyVerticalZoom()
        updatePlayhead()
    }

    /// The scroll view's content: as wide as the timeline, as tall as the viewport plus the pitch
    /// scroll, its offset put in step with the geometry unless the offset is what moved (a pan,
    /// which may be bouncing past an end); then the bands over the window.
    func layoutBands(followingOffset: Bool = false) {
        let k = geometry.scale
        let viewport = scrollView.bounds.size
        let contentSize = CGSize(width: geometry.contentWidth, height: viewport.height + pitchScrollExtent)

        isSettingOffset = true
        if scrollView.contentSize != contentSize {
            scrollView.contentSize = contentSize
        }

        let offsetY = min(max(0, pitchScrollOffset), pitchScrollExtent)

        if !followingOffset, abs(scrollView.contentOffset.y - offsetY) > 0.5 {
            scrollView.contentOffset.y = offsetY
        }
        isSettingOffset = false

        let top = scrollView.contentOffset.y
        let window = desiredBandWindow()
        let moved = window != bandWindow
        bandWindow = window

        place(waveform, CGRect(x: window.minX, y: top, width: window.width, height: geometry.waveformHeight * k))
        place(ruler, CGRect(x: window.minX, y: top + geometry.waveformHeight * k, width: window.width,
                            height: TimelineMetrics.rulerHeight * k))
        place(chordLane, CGRect(x: window.minX, y: top + geometry.chordLaneY * k, width: window.width,
                                height: geometry.chordLaneHeight * k))
        place(roll, CGRect(x: window.minX, y: top + geometry.rollY * k, width: window.width,
                           height: max(0, viewport.height - geometry.rollY * k)))

        if moved {
            placeOverlays()
        }
    }

    /// A band's frame is where its window sits in the document, and its bounds origin is the same
    /// x, so the band draws in document coordinates. A new stretch, or a new height, repaints it;
    /// moving down with the pinned header does not.
    private func place(_ band: UIView, _ frame: CGRect) {
        let stretchChanged = band.bounds.origin.x != frame.minX || band.bounds.size != frame.size

        if band.frame != frame {
            band.frame = frame
        }

        if band.bounds.origin.x != frame.minX {
            band.bounds.origin = CGPoint(x: frame.minX, y: 0)
        }

        if stretchChanged {
            band.setNeedsDisplay()
        }
    }

    /// The Mac's `desiredBandWindow`: `bandWindowViewports` wide, centred on the viewport and
    /// inside the content, kept while the viewport stays clear of its ends.
    private func desiredBandWindow() -> CGRect {
        let contentWidth = geometry.contentWidth
        let clipMinX = scrollView.contentOffset.x
        let viewport = max(scrollView.bounds.width, 1)
        let clipMaxX = clipMinX + viewport
        let width = min(contentWidth, (viewport * TimelineTouchView.bandWindowViewports).rounded())
        let margin = viewport * TimelineTouchView.bandSlideMargin
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

    // MARK: - The pitch axis as a scroll

    /// The highest `firstKey` the keyboard allows, the top of the range at the top of the column.
    private var maxFirstKey: Double {
        let saved = geometry.firstKey
        geometry.firstKey = Double(geometry.pitchRange.high)
        geometry.settleFirstKey()
        let highest = geometry.firstKey
        geometry.firstKey = saved

        return highest
    }

    /// How far the lanes can pan, in points: a semitone a lane (`rowHeight`) tall, as the Mac's
    /// wheel counts it. Zero when the whole range fits.
    var pitchScrollExtent: CGFloat {
        CGFloat(max(0, maxFirstKey - Double(geometry.pitchRange.low))) * geometry.rowHeight * geometry.scale
    }

    /// The offset that shows `firstKey`: zero is the top of the range.
    private var pitchScrollOffset: CGFloat {
        CGFloat(maxFirstKey - geometry.firstKey) * geometry.rowHeight * geometry.scale
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSettingOffset, geometry.rowHeight > 0 else { return }

        // The vertical offset is the pitch: the lanes and the keys follow it.
        let offsetY = min(max(0, scrollView.contentOffset.y), pitchScrollExtent)
        let firstKey = maxFirstKey - Double(offsetY / (geometry.rowHeight * geometry.scale))

        if abs(firstKey - geometry.firstKey) > 1e-9 {
            geometry.firstKey = firstKey
            geometry.settleFirstKey()
            roll.setNeedsDisplay()
            keyboard.setNeedsDisplay()
        }

        layoutBands(followingOffset: true)
        wakeDisplayLink()
    }

    // MARK: - Repaint

    func repaintAll() {
        for band in [waveform, ruler, chordLane, roll, keyboard, gutter] as [UIView] {
            band.setNeedsDisplay()
        }
    }
}
