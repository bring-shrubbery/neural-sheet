import AppKit
import NeuralSheetCore
import Observation
import SwiftUI

/// The Score tab's block (score design §5): a vertically scrolling ``ScoreView`` that mirrors the
/// model — the notes, the grid, the key and the arrangement rebuild the document and the layout,
/// the width relays the systems or the pages, the playhead moves the cursor, the tab selection
/// repaints — seeks on a click on empty score and selects a tab note on a click on its number.
/// A click on a part's name opens its ``PartDisplayCard`` and a right-click on a fret number the
/// note's ``StringCard``, both in one floating panel at the pointer (arrangement design §4, §6).
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
    /// The part card's and the string card's panel; one at a time.
    private let card = PopupMenuPresenter()

    /// What the last sync built the document from.
    private var lastNotes: [NoteEvent] = []
    private var lastGrid = TempoGrid()
    private var lastKey: MusicalKey?
    private var lastArrangement = ScoreArrangement()
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
        scrollView.backgroundColor = NSColor(cgColor: ScoreRenderer.Style.screen.paper) ?? .black
        scrollView.documentView = score
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        score.onSeek = { [weak self] measure, units in
            guard let self else { return }

            self.model.seek(toSeconds: self.score.document.seconds(atMeasure: measure, units: units, grid: self.model.editor.grid))
        }

        score.onSelectTabNote = { [weak self] hit in
            guard let self else { return }

            if let hit {
                self.model.selectTabNote(program: hit.program, id: hit.id)
            } else {
                self.model.deselectTabNote()
            }
        }

        score.onRightClickTabNote = { [weak self] hit, windowPoint in
            self?.showStringCard(for: hit, at: windowPoint)
        }

        score.onClickPartName = { [weak self] program, windowPoint in
            self?.showPartCard(for: program, at: windowPoint)
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
        } else {
            // Leaving the Score tab takes this view out of the window; a card left up would
            // outlive what it was for.
            card.dismiss()
        }
    }

    // MARK: - Cards

    /// The string card for a right-clicked fret number: the note's sounding pitch comes from
    /// the document the number was drawn from.
    private func showStringCard(for hit: TabHit, at windowPoint: NSPoint) {
        guard let window, let pitch = soundingPitch(program: hit.program, id: hit.id) else { return }

        let card = card
        let model = model

        card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: scale) {
            StringCard(model: model, hit: hit, pitch: pitch, host: card)
        }
    }

    private func showPartCard(for program: Int, at windowPoint: NSPoint) {
        guard let window else { return }

        let card = card
        let model = model

        card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: scale) {
            PartDisplayCard(model: model, program: program, host: card)
        }
    }

    private func soundingPitch(program: Int, id: NoteID) -> Int? {
        guard let tab = score.document.parts.first(where: { $0.program == program })?.tab else { return nil }

        for measure in tab.measures {
            for piece in measure.pieces {
                if let note = piece.notes.first(where: { $0.id == id }) { return note.pitch }
            }
        }

        return nil
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
            _ = model.arrangement
            _ = model.selectedTabNote
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

    /// Rebuilds what changed: the document on the notes, the grid, the key or the arrangement;
    /// the layout on the document or the width; a repaint on the tab selection; the cursor
    /// every time.
    func sync() {
        let model = self.model
        let notes = model.notes
        let grid = model.editor.grid
        let key = model.editor.key
        let arrangement = model.arrangement

        if !hasDocument || notes != lastNotes || grid != lastGrid || key != lastKey || arrangement != lastArrangement {
            lastNotes = notes
            lastGrid = grid
            lastKey = key
            lastArrangement = arrangement
            hasDocument = true
            score.arrangement = arrangement
            score.document = model.scoreDocument()
            relayout()
        }

        let selected = model.selectedTabNote

        if selected?.program != score.selectedTabNote?.program || selected?.id != score.selectedTabNote?.id {
            score.selectedTabNote = selected
            score.needsDisplay = true
        }

        if score.takeName != model.droppedFileName {
            score.takeName = model.droppedFileName
            score.needsDisplay = true
        }

        updateCursor()
        observeModel()
    }

    /// Lays the document out at the scroll view's width; with no width yet there is no layout,
    /// never a stale one a shrunk document could index out of range.
    private func relayout() {
        let width = scrollView.contentSize.width

        guard width > 0 else {
            score.layout = nil
            return
        }

        layoutWidth = width
        let layout = ScoreLayout(document: score.document, arrangement: model.arrangement, width: width, scale: scale)
        score.layout = layout
        // The surround shows past the last page and under a short score.
        scrollView.backgroundColor = NSColor(cgColor: layout.mode == .pages ? ScoreView.surround : ScoreRenderer.Style.screen.paper) ?? .black
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
