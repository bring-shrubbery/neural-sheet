import NeuralSheetCore
import Observation
import UIKit

/// The model mirror: the Mac's `TimelineContainerView+Model` for the touch timeline. Observation
/// tracking arms on what the timeline draws; a change schedules one sync, which compares with
/// what it last applied and repaints only the bands a change touched.
extension TimelineTouchView {
    struct Snapshot: Equatable {
        var duration: Double = 0
        var canPlay = false
        var notes: [NoteEvent] = []
        var ids: [NoteID] = []
        var selection: Set<NoteID> = []
        var mixer = InstrumentMixerState()
        var highlightedProgram: Int?
        var grid = TempoGrid()
        var key: MusicalKey?
        var chords: [ChordEvent] = []
        var markers: [Marker] = []
        var range: Range<Double>?
        var frontier: Double?
        var peaksIdentity: ObjectIdentifier?
        var zoomLevel: Double = 1
        var verticalZoom: Double = -1
        var transportRunning = false
    }

    /// What the model holds now, read inside the observation tracker.
    private func read() -> Snapshot {
        let notes = model.timelineNotes

        return Snapshot(duration: model.duration,
                        canPlay: model.canPlay,
                        notes: notes.map(\.note),
                        ids: notes.map(\.id),
                        selection: model.editor.selection,
                        mixer: model.mixer,
                        highlightedProgram: model.highlightedProgram,
                        grid: model.editor.grid,
                        key: model.editor.key,
                        chords: model.editor.chords,
                        markers: model.editor.markers,
                        range: model.editor.range,
                        frontier: model.run.map(\.finalizedThrough),
                        peaksIdentity: model.source.map { ObjectIdentifier($0.peaks) },
                        zoomLevel: model.zoomLevel,
                        verticalZoom: model.verticalZoom,
                        transportRunning: model.isTransportRunning)
    }

    /// Applies what changed since the last sync, then arms the next one.
    func sync() {
        isObservationArmed = false

        let new = withObservationTracking { read() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.sync() }
        }
        isObservationArmed = true

        let old = snapshot
        let first = !hasSynced
        snapshot = new
        hasSynced = true

        if first || new.duration != old.duration || new.notes.last?.endTime != old.notes.last?.endTime {
            geometry.duration = new.duration
            geometry.notesEnd = new.notes.map(\.endTime).max() ?? 0
        }

        if first || new.canPlay != old.canPlay {
            roll.painter.canPlay = new.canPlay
            ruler.painter.canPlay = new.canPlay
            repaintAll()
        }

        if first || new.peaksIdentity != old.peaksIdentity {
            waveform.peaks = model.source?.peaks
            waveform.setNeedsDisplay()
        }

        if first || new.notes != old.notes || new.ids != old.ids {
            roll.painter.notes = new.notes
            roll.painter.ids = new.ids
            roll.painter.buckets = RollPainter.secondBuckets(new.notes)
            roll.painter.refreshPreviewIndices()
            roll.setNeedsDisplay()
        }

        if first || new.selection != old.selection {
            roll.painter.selection = new.selection
            roll.setNeedsDisplay()
        }

        if first || new.mixer != old.mixer || new.highlightedProgram != old.highlightedProgram {
            for program in 0...NoteEvent.drumProgram {
                roll.painter.audible[program] = new.mixer.isAudible(program: program)
            }
            roll.painter.highlightedProgram = new.highlightedProgram
            roll.setNeedsDisplay()
        }

        if first || new.grid != old.grid || new.key != old.key {
            roll.painter.grid = new.grid
            roll.painter.key = new.key
            ruler.painter.grid = new.grid
            ruler.painter.tempoMap = new.grid
            keyboard.key = new.key
            repaintAll()
        }

        if first || new.chords != old.chords || new.key != old.key {
            chordLane.chords = new.chords
            chordLane.labels = new.chords.map { $0.text(in: new.key) }
            geometry.chordLaneHeight = new.chords.isEmpty ? 0 : ChordLanePainter.height
            chordLane.setNeedsDisplay()
            gutter.setNeedsDisplay()
            setNeedsLayout()
        }

        if first || new.markers != old.markers {
            ruler.painter.markers = new.markers
            ruler.setNeedsDisplay()
        }

        // The zoom the project opened with, or one set from elsewhere.
        if first || abs(new.zoomLevel - geometry.zoom) > 1e-9 && new.zoomLevel != old.zoomLevel {
            geometry.zoom = new.zoomLevel
        }

        if first || new.notes != old.notes || new.verticalZoom != old.verticalZoom || new.frontier != old.frontier {
            applyVerticalZoom()
        }

        setZoom(geometry.zoom, keepingSecondsAtX: nil)
        placeOverlays()
        updatePlayhead()
        wakeDisplayLink()
    }

    // MARK: - Zoom

    /// The take's length the zoom is clamped against: none until there is a take.
    private var clampDuration: Double { geometry.duration }

    /// `_setZoomLevel`: clamps, applies, keeps the time under `x` (viewport points) where it was,
    /// and writes the effective value back to the model.
    func setZoom(_ zoom: Double, keepingSecondsAtX anchorX: CGFloat?) {
        let viewportAuthored = Double(scrollView.bounds.width / geometry.scale)
        let clamped = ZoomMath.clampHorizontal(zoom, viewportWidth: viewportAuthored, duration: clampDuration)
        let anchor = anchorX.map { geometry.seconds(forX: scrollView.contentOffset.x + $0) }
        let changed = abs(clamped - geometry.zoom) > 1e-9

        geometry.zoom = clamped

        if hasSynced {
            snapshot.zoomLevel = clamped
            model.setZoomLevel(clamped)
        }

        layoutBands()

        if let anchor, let anchorX {
            let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            isSettingOffset = true
            scrollView.contentOffset.x = min(max(0, geometry.x(forSeconds: anchor) - anchorX), maxX)
            isSettingOffset = false
            layoutBands()
        }

        if changed {
            waveform.setNeedsDisplay()
            ruler.setNeedsDisplay()
            chordLane.setNeedsDisplay()
            roll.setNeedsDisplay()
            placeOverlays()
            updatePlayhead()
        }
    }

    /// `VisualizationPanel::_applyVerticalZoom`: the stored zoom, or the one that fits the
    /// transcription's octaves; then the range re-derived against it.
    func applyVerticalZoom() {
        guard geometry.keyboardHeight > 0 else { return }

        var norm = model.verticalZoom

        if norm < 0 {
            let pitches = snapshot.notes.map(\.pitch)
            let content = PianoRollRange.displayRange(notes: pitches.min(), highest: pitches.max(), minSemitones: 0)

            norm = ZoomMath.normForFit(visibleHeight: Double(geometry.keyboardHeight), semitones: content.count)
        }

        if geometry.setRowHeight(CGFloat(ZoomMath.rowHeight(norm: norm))) {
            keyboard.setNeedsDisplay()
            roll.setNeedsDisplay()
        }

        updateNoteRange(mayShrink: model.run == nil)
        layoutBands()
    }

    /// `VisualizationPanel::_updateNoteRange`: whole octaves covering every note and filling the
    /// column; while a run streams the range may only widen.
    func updateNoteRange(mayShrink: Bool) {
        let pitches = snapshot.notes.map(\.pitch)
        let minSemitones = geometry.rowHeight > 0
            ? Int((geometry.keyboardHeight / geometry.rowHeight - 1e-6).rounded(.up))
            : 0

        var range = PianoRollRange.displayRange(notes: pitches.min(), highest: pitches.max(),
                                                minSemitones: max(0, minSemitones))

        if !mayShrink {
            range = PianoRollRange.union(range, geometry.pitchRange)
        }

        if keyboard.isDimmed != pitches.isEmpty {
            keyboard.isDimmed = pitches.isEmpty
            keyboard.setNeedsDisplay()
        }

        if range != geometry.pitchRange {
            geometry.pitchRange = range
            geometry.settleFirstKey()
            keyboard.setNeedsDisplay()
            roll.setNeedsDisplay()
        }
    }

    // MARK: - Overlays

    /// The range bands and the decode frontier, laid out again whenever they or the window move.
    func placeOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        roll.rangeBand.place(snapshot.range, geometry: geometry, height: roll.bounds.height)
        waveform.rangeBand.place(snapshot.range, geometry: geometry, height: waveform.bounds.height)

        // `PianoRoll::_drawTranscriptionFrontier`: everything right of it shaded while a run goes.
        if let frontier = snapshot.frontier, geometry.x(forSeconds: frontier) < roll.bounds.maxX {
            let x = geometry.x(forSeconds: frontier)
            let k = geometry.scale
            roll.frontierShade.set(frame: CGRect(x: x, y: 0, width: roll.bounds.maxX - x, height: roll.bounds.height))
            roll.frontierLine.set(frame: CGRect(x: (x / k).rounded() * k, y: 0, width: k, height: roll.bounds.height))
        } else {
            roll.frontierShade.set(frame: nil)
            roll.frontierLine.set(frame: nil)
        }

        CATransaction.commit()
    }
}
