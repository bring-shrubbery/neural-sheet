import NeuralSheetCore
import QuartzCore
import UIKit

/// The touch score (iOS app design §2, sub-issue G): the Mac's `ScoreContainerView` over UIKit.
/// A `UIScrollView` whose content is the shared ``ScoreLayout`` -- the systems down a continuous
/// column at the view's width, or the pages on their surround -- drawn by the Mac's
/// ``ScorePainter`` into a canvas at the screen's scale, with the playhead cursor as a view of its
/// own so it moves without a repaint. Read-only: a tap on empty score seeks, a tap on a part's
/// name opens its display sheet, a pinch scales the score, and while the take plays the system
/// under the cursor is kept in view.
///
/// The canvas is a window a couple of viewports tall that slides with the scroll
/// (``layoutCanvas()``), never a layer the height of a long score, as the timeline's bands are.
final class ScoreTouchView: UIView, UIScrollViewDelegate {
    let model: MobileModel
    let scrollView = UIScrollView()
    let canvas = ScoreCanvasView()
    let cursor = UIView()

    /// The score's scale, pinched; 1 is the Mac's staff space. Not saved.
    var scale: CGFloat = 1

    /// The scale range a pinch is held to.
    static let scaleRange: ClosedRange<CGFloat> = 0.6 ... 2.5
    /// How many viewports tall and wide the canvas may be, and how close to its edge the viewport may come
    /// before it slides to centre on it again.
    static let canvasViewports: CGFloat = 2
    static let canvasViewportsAcross: CGFloat = 1.5
    static let canvasSlideMargin: CGFloat = 0.2
    /// The room left and right of a page in the pages layout at the fitted scale.
    static let pageInset: CGFloat = 12

    /// A tap on a part's name, with its program.
    var onPartName: ((Int) -> Void)?

    /// What the last sync built the score from (`+Sync`).
    var inputs: Inputs?
    var isObservationArmed = false
    var layoutWidth: CGFloat = 0
    var cursorSystemIndex: Int?
    var pinchStartScale: CGFloat = 1
    var isPinching = false

    /// The display link that moves the cursor while the take plays (`+Sync`).
    var displayLink: CADisplayLink?

    init(model: MobileModel) {
        self.model = model
        super.init(frame: .zero)

        // The staves run left to right in every language (localization design §2).
        semanticContentAttribute = .forceLeftToRight
        backgroundColor = UIColor(cgColor: ScoreRenderer.Style.screen.paper)

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = UIColor(cgColor: ScoreRenderer.Style.screen.paper)
        scrollView.semanticContentAttribute = .forceLeftToRight
        addSubview(scrollView)

        canvas.isOpaque = true
        canvas.contentMode = .redraw
        scrollView.addSubview(canvas)

        cursor.backgroundColor = UIColor(cgColor: ScoreRenderer.Style.screen.cursor)
        cursor.isUserInteractionEnabled = false
        cursor.isHidden = true
        scrollView.addSubview(cursor)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        isAccessibilityElement = false
        scrollView.accessibilityLabel = String(localized: "Score", comment: "Tab: the score")
        scrollView.accessibilityIdentifier = "score"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            // A change while away un-armed the tracker; without one the score is as it was.
            if isObservationArmed {
                updateCursor()
            } else {
                sync()
            }

            startDisplayLink()
            wakeDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        scrollView.frame = bounds

        if bounds.width != layoutWidth {
            relayout()
        } else {
            layoutCanvas()
        }
    }

    // MARK: - Layout

    /// The layout at the view's width and the pinched scale; in the pages layout the scale is
    /// first fitted so a page fits the width, which on a phone is narrower than a sheet of paper.
    /// With no width yet there is no layout, never a stale one.
    func relayout() {
        let width = bounds.width
        layoutWidth = width

        guard width > 0, let inputs else {
            canvas.painter.layout = nil
            canvas.setNeedsDisplay()
            return
        }

        let document = canvas.painter.document
        var layoutScale = scale

        if inputs.arrangement.layout == .pages {
            let pageWidth = inputs.arrangement.pageSize.points.width
            layoutScale *= min(1, (width - 2 * Self.pageInset) / pageWidth)
        }

        let layout = ScoreLayout(document: document, arrangement: inputs.arrangement, width: width, scale: layoutScale)
        let contentWidth = max(width, (layout.pageFrames.map(\.maxX).max() ?? 0) + Self.pageInset)
        let fraction = scrollView.contentSize.height > 0 ? scrollView.contentOffset.y / scrollView.contentSize.height : 0

        canvas.painter.layout = layout
        canvas.contentBounds = CGRect(x: 0, y: 0, width: contentWidth, height: max(layout.totalHeight, bounds.height))
        scrollView.contentSize = canvas.contentBounds.size
        scrollView.backgroundColor = UIColor(cgColor: layout.mode == .pages ? ScoreLayout.surround : ScoreRenderer.Style.screen.paper)

        // A pinch or a rotation keeps the same part of the score in view.
        let maxY = max(0, scrollView.contentSize.height - bounds.height)
        scrollView.contentOffset = CGPoint(x: min(scrollView.contentOffset.x, max(0, contentWidth - width)),
                                           y: min(max(0, fraction * scrollView.contentSize.height), maxY))

        canvas.span = nil
        cursorSystemIndex = nil
        layoutCanvas()
        updateCursor()
    }

    /// Slides the canvas to cover the viewport with room around it, repainting only when it
    /// moves. Wider than the view only when a zoomed page is.
    func layoutCanvas() {
        let content = canvas.contentBounds
        let visible = CGRect(origin: scrollView.contentOffset, size: bounds.size)

        guard content.width > 0, visible.height > 0 else { return }

        let size = CGSize(width: min(content.width, visible.width * Self.canvasViewportsAcross),
                          height: min(content.height, visible.height * Self.canvasViewports))
        let marginX = visible.width * Self.canvasSlideMargin
        let marginY = visible.height * Self.canvasSlideMargin

        if let span = canvas.span, span.size == size,
           visible.minX >= span.minX + (span.minX > 0 ? marginX : 0),
           visible.maxX <= span.maxX - (span.maxX < content.maxX ? marginX : 0),
           visible.minY >= span.minY + (span.minY > 0 ? marginY : 0),
           visible.maxY <= span.maxY - (span.maxY < content.maxY ? marginY : 0) {
            return
        }

        let x = min(max(0, visible.midX - size.width / 2), content.width - size.width)
        let y = min(max(0, visible.midY - size.height / 2), content.height - size.height)
        let span = CGRect(origin: CGPoint(x: x, y: y), size: size)

        canvas.span = span
        canvas.frame = span
        canvas.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutCanvas()
    }

    // MARK: - Touch

    /// A part's name opens its sheet; anywhere else on the music seeks there, through the grid.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let layout = canvas.painter.layout else { return }

        let point = recognizer.location(in: scrollView)

        if let name = canvas.painter.nameHit(at: point) {
            onPartName?(name.program)
            return
        }

        guard let hit = layout.hitTest(point) else { return }

        model.seek(toSeconds: canvas.painter.document.seconds(atMeasure: hit.measure, units: hit.units, grid: model.editor.grid))
        updateCursor()
    }

    /// The score's scale, from where the pinch began, relaid out as it goes once the change is
    /// big enough to see.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartScale = scale
            isPinching = true
        case .changed:
            let target = min(max(pinchStartScale * recognizer.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)

            if abs(target - scale) / scale > 0.03 {
                scale = target
                relayout()
            }
        default:
            isPinching = false
            let target = min(max(pinchStartScale * recognizer.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)

            if target != scale {
                scale = target
                relayout()
            }
        }
    }
}

/// The canvas: the shared painter drawing the part of the score under the canvas's own
/// frame in the scroll view's content, `span`.
final class ScoreCanvasView: UIView {
    var painter = ScorePainter()
    /// The whole score's bounds, the content size.
    var contentBounds = CGRect.zero
    /// Where the canvas sits in the content; nil until laid out.
    var span: CGRect?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let origin = frame.origin
        ctx.translateBy(x: -origin.x, y: -origin.y)
        painter.draw(rect.offsetBy(dx: origin.x, dy: origin.y), bounds: contentBounds, in: ctx)
    }
}
