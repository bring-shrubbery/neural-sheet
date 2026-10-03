import Foundation
import NeuralSheetCore

/// The timeline's side of the model (sub-issue E): what the touch roll draws, and what its
/// gestures ask for -- seek, select, audition, mark a range, zoom -- plus the placeholder
/// transport's play and pause until sub-issue H brings the real one. The rules are the Mac's
/// (`AppModel+Playback`, `+Editing`), without the window.
extension MobileModel {
    /// The notes the roll draws: the document's, or while a run streams what it has found so far,
    /// under placeholder ids nothing hit-tests (as the Mac's roll does).
    var timelineNotes: [EditableNote] {
        if let document { return document.notes }

        return streamedNotes.enumerated().map { EditableNote(id: NoteID($0.offset), note: $0.element) }
    }

    /// Whether a run is streaming, so the roll's notes are placeholders.
    var notesArePlaceholders: Bool { document == nil }

    /// There is a take to play and seek over.
    var canPlay: Bool { source != nil && recording == nil }

    var isPlaying: Bool { engine.isPlaying }

    // MARK: - Transport (placeholder until sub-issue H)

    /// Play or pause, starting the engine first if it is not running.
    func togglePlay() {
        guard canPlay else { return }

        if engine.isPlaying {
            engine.pause()
            playheadSeconds = engine.playheadSeconds
            return
        }

        guard startEngineIfNeeded() else { return }

        engine.play()
    }

    /// A tap on the roll's empty lanes, the ruler or the waveform: the playhead there, as the
    /// Mac's click does. Ignored past the end of the take, as the engine ignores it.
    func seek(toSeconds seconds: Double) {
        guard canPlay else { return }

        engine.seek(seconds: seconds)
        playheadSeconds = engine.playheadSeconds
    }

    // MARK: - Selection and audition

    /// A tap on a note selects it alone; nil clears the selection. Not while a run streams.
    func select(_ id: NoteID?) {
        guard document != nil else { return }

        let selection: Set<NoteID> = id.map { [$0] } ?? []

        if editor.selection != selection {
            editor.selection = selection
        }
    }

    /// The note a tap selected, sounded through its own synth (the Mac's audition on a click).
    func audition(_ note: NoteEvent) {
        guard startEngineIfNeeded() else { return }

        engine.synthBank.audition(program: note.program, pitch: note.pitch, velocity: note.velocity,
                                  seconds: MobileModel.auditionSeconds(note))
    }

    /// A key in the keyboard gutter, in the target instrument.
    func audition(pitch: Int) {
        guard startEngineIfNeeded() else { return }

        engine.synthBank.audition(program: editor.targetProgram, pitch: pitch, velocity: 100, seconds: 0.5)
    }

    /// As long as the note, within reason: a long note is cut off, a drum hit rings out.
    static func auditionSeconds(_ note: NoteEvent) -> Double {
        min(max(note.endTime - note.startTime, 0.15), 1.5)
    }

    // MARK: - Range

    /// The ruler's drag, the Mac's `setRange`: clamped to the take; a sliver is no range.
    func setRange(_ range: Range<Double>) {
        guard canPlay, run == nil else { return }

        let lower = max(0, range.lowerBound)
        let upper = min(duration, range.upperBound)

        guard upper - lower >= RegionSlice.minimumRangeSeconds else {
            if editor.range != nil { editor.range = nil }
            return
        }

        if editor.range != lower ..< upper {
            editor.range = lower ..< upper
        }
    }

    // MARK: - Zoom

    /// The horizontal zoom the timeline settled on, saved with the project.
    func setZoomLevel(_ zoom: Double) {
        if abs(zoomLevel - zoom) > 1e-9 {
            zoomLevel = zoom
        }
    }

    /// The vertical zoom, 0…1, or −1 to fit the notes' octaves; saved with the project.
    func setVerticalZoom(_ norm: Double) {
        if abs(verticalZoom - norm) > 1e-9 {
            verticalZoom = norm
        }
    }

    // MARK: - Engine

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }

        do {
            try engine.start()
            return true
        } catch {
            alert = MobileAlert(title: Self.errorTitle, message: PlaybackEngine.describe(error))
            return false
        }
    }
}
