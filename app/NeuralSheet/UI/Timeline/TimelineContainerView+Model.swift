import AppKit
import NeuralSheetCore
import Observation

/// What the timeline mirrors from the model, and how: observation tracking that schedules one
/// sync per burst of writes, and a sync that repaints only what moved.
extension TimelineContainerView {
    // MARK: - Model observation

    /// Reads everything the timeline draws from, so the next write to any of it schedules a sync.
    /// One shot: re-armed by ``sync()``, and never doubled — a tracker that has not fired yet is
    /// still valid.
    private func observeModel() {
        guard !isObservationArmed else { return }

        isObservationArmed = true

        withObservationTracking {
            let model = self.model
            _ = model.state
            _ = model.isPlaying
            _ = model.duration
            _ = model.zoomLevel
            _ = model.verticalZoom
            _ = model.goToStartGeneration
            _ = model.notes
            _ = model.finalizedThrough
            _ = model.mixer
            _ = model.highlightedProgram
            _ = model.installedModels
            _ = model.transcribeLabel
            _ = model.canTranscribe
            _ = model.peaks
            _ = model.workspace
            _ = model.document
            _ = model.editor.grid
            _ = model.editor.selection
            _ = model.editor.tool
        } onChange: { [weak self] in
            // Called before the new value lands, from whichever context wrote it: the read has to
            // wait for the next run-loop pass, which also folds a burst of writes into one sync.
            DispatchQueue.main.async {
                self?.isObservationArmed = false
                self?.scheduleSync()
            }
        }
    }

    /// Off-window the change is dropped without re-arming; `viewDidMoveToWindow` syncs, and arms.
    private func scheduleSync() {
        guard window != nil else { return }

        sync()
    }

    /// Compares the model to the last snapshot and repaints exactly what moved.
    func sync() {
        let model = self.model
        let new = Snapshot(state: model.state,
                           isPlaying: model.isPlaying,
                           duration: model.duration,
                           zoomLevel: model.zoomLevel,
                           verticalZoom: model.verticalZoom,
                           goToStartGeneration: model.goToStartGeneration,
                           finalizedThrough: model.finalizedThrough,
                           mixer: model.mixer,
                           highlightedProgram: model.highlightedProgram,
                           hasModel: !model.installedModels.isEmpty,
                           transcribeLabel: model.transcribeLabel,
                           canTranscribe: model.canTranscribe,
                           peaksIdentity: ObjectIdentifier(model.peaks),
                           workspace: model.workspace,
                           grid: model.editor.grid,
                           selection: model.editor.selection,
                           tool: model.editor.tool)
        let old = snapshot
        let first = !hasSynced
        // The document's identified notes, or the run's placeholders (ids nothing hit-tests).
        let notes = model.notes
        let identified = model.document?.notes ?? notes.enumerated().map { EditableNote(id: NoteID($0.offset), note: $0.element) }
        let ids = identified.map(\.id)
        let notesChanged = first || notes != lastNotes || ids != lastNoteIDs

        snapshot = new
        hasSynced = true

        let stateChanged = first || new.state != old.state
        let audioChanged = first || new.peaksIdentity != old.peaksIdentity
            || (new.duration != old.duration && new.state != .recording)
        let zoomChanged = first || new.zoomLevel != old.zoomLevel

        if audioChanged {
            waveform.peaks = model.peaks
            geometry.duration = new.duration
        }

        // Before the zoom and state handling, so the bands are laid out for the tab's waveform
        // height in the same pass.
        if first || new.workspace != old.workspace {
            mode = new.workspace == .edit ? .edit : .transcribe
        }

        if mode == .edit, first || new.grid != old.grid || new.workspace != old.workspace {
            ruler.grid = new.grid
            roll.grid = new.grid
            ruler.needsDisplay = true
            roll.needsDisplay = true
        }

        if zoomChanged {
            // Reset Zoom, or a restored session: applied anchored on the left edge, like a wheel,
            // and clamped against the take that is there now.
            setZoomAnchored(new.zoomLevel)
        } else if stateChanged || audioChanged {
            // Loading a shorter take can leave the view zoomed out past the end of it.
            refreshForAudioLength()
        }

        if stateChanged || audioChanged {
            waveform.needsDisplay = true
            ruler.canPlay = new.state.canPlay
            roll.canPlay = new.state.canPlay
            ruler.needsDisplay = true
            roll.needsDisplay = true

            if new.state == .empty {
                scroll(toX: 0)
            }
        }

        if notesChanged {
            lastNotes = notes
            lastNoteIDs = ids
            roll.setNotes(identified)
            roll.needsDisplay = true
        }

        if first || new.mixer != old.mixer {
            roll.setMixer(new.mixer)
        }

        if first || new.highlightedProgram != old.highlightedProgram {
            roll.setHighlightedProgram(new.highlightedProgram)
        }

        // The controller sets the selection as it is installed; from then on the roll follows the
        // model (a marquee, a key, an undo). Outside Edit mode the roll shows none.
        if mode == .edit {
            if new.selection != old.selection {
                roll.setSelection(new.selection)
            }

            if new.tool != old.tool {
                roll.refreshCursor()
                roll.window?.invalidateCursorRects(for: roll)
            }
        }

        // The range: every state change settles it on what is there, a chunk may only widen it,
        // and a vertical zoom re-derives it against the new key height.
        if first || new.verticalZoom != old.verticalZoom || new.state != previousStateForRange {
            previousStateForRange = new.state
            applyVerticalZoom()
        } else if notesChanged || new.mixer != old.mixer {
            updateNoteRange(mayShrink: false)
        }

        if stateChanged || first || new.finalizedThrough != old.finalizedThrough {
            frontierSeconds = new.state == .processing ? new.finalizedThrough : nil
            roll.setFrontier(seconds: frontierSeconds)
        }

        if first || new.goToStartGeneration != old.goToStartGeneration {
            scroll(toX: 0)
        }

        if stateChanged || first || new.hasModel != old.hasModel || new.transcribeLabel != old.transcribeLabel
            || new.canTranscribe != old.canTranscribe
        {
            placeOverlays()
        }

        updatePlayhead()
        resumeDisplayLink()
        observeModel()
    }

    // MARK: - Vertical zoom and pitch range

    /// `VisualizationPanel::_applyVerticalZoom`: the stored zoom, or the one that fits the
    /// transcription's octaves, pushed into the geometry; then the range re-derived against it.
    func applyVerticalZoom() {
        guard geometry.keyboardHeight > 0 else { return }

        var norm = model.verticalZoom

        if norm < 0 {
            // Fit to the octaves the transcription occupies, not to the notes themselves: those
            // octaves are what the roll ends up drawing, so fitting to anything narrower crops it.
            let status = model.statusLine
            let content = PianoRollRange.displayRange(notes: status.lowest, highest: status.highest, minSemitones: 0)

            norm = ZoomMath.normForFit(visibleHeight: Double(geometry.keyboardHeight), semitones: content.count)

            if model.fittedVerticalZoom != norm {
                model.fittedVerticalZoom = norm
            }
        }

        if geometry.setRowHeight(CGFloat(ZoomMath.rowHeight(norm: norm))) {
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }

        updateNoteRange(mayShrink: model.state != .processing)
    }

    /// `VisualizationPanel::_updateNoteRange`: whole octaves covering every note and filling the
    /// column; while a run streams in the range may only widen.
    func updateNoteRange(mayShrink: Bool) {
        let status = model.statusLine
        let hasNotes = !model.notes.isEmpty
        let minSemitones = geometry.rowHeight > 0
            ? Int((geometry.keyboardHeight / geometry.rowHeight - 1e-6).rounded(.up))
            : 0

        var range = PianoRollRange.displayRange(notes: status.lowest, highest: status.highest,
                                                minSemitones: max(0, minSemitones))

        if !mayShrink {
            range = PianoRollRange.union(range, geometry.pitchRange)
        }

        keyboard.isDimmed = !hasNotes

        if range != geometry.pitchRange {
            geometry.pitchRange = range
            geometry.settleFirstKey()
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }
    }
}
