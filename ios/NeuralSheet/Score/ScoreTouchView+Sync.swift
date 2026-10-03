import NeuralSheetCore
import Observation
import QuartzCore
import UIKit

/// The model mirror and the playhead: the Mac's `ScoreContainerView.sync` and `updateCursor` for
/// the touch score. Observation tracking arms on what the score is built from; a change rebuilds
/// the document and the layout only when one of those changed. The cursor is moved by a display
/// link reading the engine while the take plays, and the system under it is kept in view.
extension ScoreTouchView {
    /// What the score document and its layout are built from.
    struct Inputs: Equatable {
        var notes: [NoteEvent]
        var ids: [NoteID]?
        var grid: TempoGrid
        var key: MusicalKey?
        var chords: [ChordEvent]
        var markers: [Marker]
        var arrangement: ScoreArrangement
        var takeName: String?
    }

    /// What the model holds now, read inside the observation tracker; the transport's fields are
    /// read too so a play, a pause or a seek wakes the cursor.
    private func read() -> Inputs {
        let model = self.model
        _ = model.canPlay
        _ = model.isTransportRunning
        _ = model.playheadSeconds

        return Inputs(notes: model.document?.events ?? model.streamedNotes,
                      ids: model.document?.notes.map(\.id),
                      grid: model.editor.grid,
                      key: model.editor.key,
                      chords: model.editor.chords,
                      markers: model.editor.markers,
                      arrangement: model.arrangement,
                      takeName: model.droppedFileName)
    }

    /// Rebuilds what changed: the document and the layout on the notes, the grid, the key, the
    /// chords, the markers or the arrangement; a repaint on the take's name (the title's
    /// fallback); the cursor every time.
    func sync() {
        isObservationArmed = false

        let new = withObservationTracking { read() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.window != nil else {
                    self?.isObservationArmed = false
                    return
                }

                self.sync()
            }
        }
        isObservationArmed = true

        let old = inputs
        inputs = new

        if old == nil || new.notes != old?.notes || new.ids != old?.ids || new.grid != old?.grid || new.key != old?.key
            || new.chords != old?.chords || new.markers != old?.markers || new.arrangement != old?.arrangement {
            canvas.painter.arrangement = new.arrangement
            canvas.painter.takeName = new.takeName
            canvas.painter.document = model.scoreDocument()
            relayout()
        } else if new.takeName != old?.takeName {
            canvas.painter.takeName = new.takeName
            canvas.setNeedsDisplay()
        }

        updateCursor()
        wakeDisplayLink()
    }

    // MARK: - Cursor

    /// The cursor at the engine's playhead, hidden without a take; while the take plays, the
    /// system under it comes into view when it changes, unless a finger is on the score.
    func updateCursor() {
        guard model.canPlay, let layout = canvas.painter.layout,
              let position = canvas.painter.document.measureIndex(atSeconds: model.engine.playheadSeconds, grid: model.editor.grid),
              let frame = layout.cursorFrame(measure: position.measure, units: position.units)
        else {
            cursor.isHidden = true
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.isHidden = false
        cursor.frame = frame
        CATransaction.commit()

        let touching = scrollView.isTracking || scrollView.isDecelerating || isPinching

        guard model.isPlaying, model.followPlayhead, !touching,
              let systemIndex = layout.systems.firstIndex(where: { $0.measures.contains { $0.index == position.measure } }),
              systemIndex != cursorSystemIndex
        else { return }

        cursorSystemIndex = systemIndex
        let system = layout.systems[systemIndex]
        let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)

        if system.frame.minY - layout.sp * 2 < visible.minY || system.frame.maxY + layout.sp * 2 > visible.maxY {
            let target = max(0, min(system.frame.minY - layout.sp * 3, scrollView.contentSize.height - visible.height))
            let x = min(max(0, system.frame.midX - visible.width / 2), max(0, scrollView.contentSize.width - visible.width))
            scrollView.contentOffset = CGPoint(x: layout.mode == .pages ? x : 0, y: target)
        }
    }

    // MARK: - Display link

    /// The link through a proxy, so its retain of the target never keeps the view alive; it is
    /// invalidated whenever the view leaves its window.
    func startDisplayLink() {
        guard displayLink == nil else { return }

        let proxy = ScoreDisplayLinkProxy()
        proxy.target = self

        let link = CADisplayLink(target: proxy, selector: #selector(ScoreDisplayLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = !model.isTransportRunning
        displayLink = link
    }

    /// Runs the link while the transport runs.
    func wakeDisplayLink() {
        displayLink?.isPaused = !model.isTransportRunning
    }

    func tick() {
        // The take ran out under the transport: Play is Play again, as the timeline does.
        if !model.isPlaying, model.isTransportRunning {
            model.isTransportRunning = false
            model.playheadSeconds = model.engine.playheadSeconds
        }

        updateCursor()

        if !model.isTransportRunning {
            displayLink?.isPaused = true
        }
    }
}

/// The display link's target: weak on the view, so the link's own retain never keeps it alive.
final class ScoreDisplayLinkProxy: NSObject {
    weak var target: ScoreTouchView?

    @objc func fire(_ link: CADisplayLink) {
        target?.tick()
    }
}
