import AppKit
import NeuralSheetCore
import Observation
import SwiftUI

/// The Score tab's block (score design §5): a vertically scrolling ``ScoreView`` that mirrors the
/// model — the notes, the grid and the key rebuild the document and the layout, the width relays
/// the systems, the playhead moves the cursor — and seeks on click.
final class ScoreContainerView: NSView {
    let model: AppModel

    var scale: CGFloat {
        didSet {
            if scale != oldValue {
                relayout()
            }
        }
    }

    private let scrollView = NSScrollView(frame: .zero)
    private let score = ScoreView(frame: .zero)

    /// What the last sync built the document from.
    private var lastNotes: [NoteEvent] = []
    private var lastGrid = TempoGrid()
    private var lastKey: MusicalKey?
    private var hasDocument = false
    private var layoutWidth: CGFloat = 0
    private var cursorSystemIndex: Int?
    private var isObservationArmed = false

    /// Authored staff space; scaled by `scale`.
    static let staffSpace: CGFloat = 8

    init(model: AppModel, scale: CGFloat) {
        self.model = model
        self.scale = scale
        super.init(frame: .zero)

        wantsLayer = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(cgColor: ScorePalette.paper) ?? .black
        scrollView.documentView = score
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        score.onSeek = { [weak self] measure, units in
            guard let self else { return }

            self.model.seek(toSeconds: self.score.document.seconds(atMeasure: measure, units: units, grid: self.model.editor.grid))
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        scrollView.frame = bounds

        if scrollView.contentSize.width != layoutWidth {
            relayout()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            sync()
        }
    }

    // MARK: - Model mirror

    private func observeModel() {
        guard !isObservationArmed else { return }

        isObservationArmed = true

        withObservationTracking {
            let model = self.model
            _ = model.notes
            _ = model.editor.grid
            _ = model.editor.key
            _ = model.state
            _ = model.isPlaying
            _ = model.playheadSeconds
            _ = model.followPlayhead
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.isObservationArmed = false
                if self?.window != nil { self?.sync() }
            }
        }
    }

    /// Rebuilds what changed: the document on the notes, the grid or the key; the layout on the
    /// document or the width; the cursor every time.
    func sync() {
        let model = self.model
        let notes = model.notes
        let grid = model.editor.grid
        let key = model.editor.key

        if !hasDocument || notes != lastNotes || grid != lastGrid || key != lastKey {
            lastNotes = notes
            lastGrid = grid
            lastKey = key
            hasDocument = true
            score.document = ScoreDocument.build(notes: notes, grid: grid, key: key)
            relayout()
        }

        updateCursor()
        observeModel()
    }

    private func relayout() {
        let width = scrollView.contentSize.width

        guard width > 0 else { return }

        layoutWidth = width
        let layout = ScoreLayout(document: score.document, width: width, sp: ScoreContainerView.staffSpace * scale)
        score.layout = layout
        score.frame = CGRect(x: 0, y: 0, width: width, height: max(layout.totalHeight, scrollView.contentSize.height))
        score.needsDisplay = true
        cursorSystemIndex = nil
        updateCursor()
    }

    private func updateCursor() {
        guard model.state.canPlay, let layout = score.layout,
              let position = score.document.measureIndex(atSeconds: model.playheadSeconds, grid: model.editor.grid)
        else {
            score.placeCursor(measure: nil, units: 0)
            return
        }

        score.placeCursor(measure: position.measure, units: position.units)

        // Follow: the system under the cursor comes into view when it changes.
        guard model.isPlaying, model.followPlayhead,
              let systemIndex = layout.systems.firstIndex(where: { $0.measures.contains { $0.index == position.measure } }),
              systemIndex != cursorSystemIndex
        else { return }

        cursorSystemIndex = systemIndex
        let system = layout.systems[systemIndex]
        let visible = scrollView.contentView.bounds

        if system.frame.minY - layout.sp * 2 < visible.minY || system.frame.maxY + layout.sp * 2 > visible.maxY {
            let target = max(0, min(system.frame.minY - layout.sp * 3, score.frame.height - visible.height))
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// The Score tab for the SwiftUI composition.
struct ScoreTabView: NSViewRepresentable {
    let model: AppModel

    @Environment(\.uiScale) private var scale

    func makeNSView(context: Context) -> ScoreContainerView {
        ScoreContainerView(model: model, scale: scale)
    }

    func updateNSView(_ view: ScoreContainerView, context: Context) {
        view.scale = scale
    }
}
