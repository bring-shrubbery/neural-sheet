import Foundation
import NeuralSheetCore

/// Per-note confidence in the app (confidence design §5): the View menu's shading toggle, the
/// Edit menu's Select Doubtful Notes, and the Model pane's After transcription settings, all kept
/// in the global settings so they are remembered across launches.
extension AppModel {
    // MARK: - Settings

    /// View → Show Confidence: the roll shades notes by confidence instead of velocity.
    var showsConfidence: Bool {
        get { settings.showsConfidence }
        set { settings.showsConfidence = newValue }
    }

    /// Settings → Model → Drop notes shorter than, in seconds; 0 is off.
    var minimumNoteLength: Double {
        get { settings.minimumNoteLength }
        set { settings.minimumNoteLength = newValue }
    }

    /// Settings → Model → Drop notes less sure than, 0…1; 0 is off.
    var minimumConfidence: Double {
        get { settings.minimumConfidence }
        set { settings.minimumConfidence = newValue }
    }

    // MARK: - Select Doubtful Notes

    /// The notes Select Doubtful Notes would pick: under 50 %, or shorter than the minimum length
    /// when that setting is on. A drawn note counts as sure, so a project from before confidence
    /// existed has none.
    private var doubtfulNoteIDs: Set<NoteID> {
        guard let document else { return [] }

        let minimumLength = settings.minimumNoteLength

        return Set(document.notes.filter { NoteFilter.isDoubtful($0.note, minimumLength: minimumLength) }.map(\.id))
    }

    /// Edit tab only, and only when it would select something. Stops at the first doubtful note:
    /// the menu asks this every time it is drawn.
    var canSelectDoubtfulNotes: Bool {
        guard workspace == .edit, canEdit, let document else { return false }

        let minimumLength = settings.minimumNoteLength

        return document.notes.contains { NoteFilter.isDoubtful($0.note, minimumLength: minimumLength) }
    }

    /// Edit → Select Doubtful Notes: replaces the selection, so Delete then removes them as one
    /// undoable batch.
    func selectDoubtfulNotes() {
        guard workspace == .edit, canEdit else { return }

        setSelection(doubtfulNoteIDs)
    }
}

extension NoteEvent {
    /// The run's notes with the After transcription settings applied: what lands, at each of the
    /// three landings (a full run, a stems run, a region). Never notes already in the document.
    nonisolated static func landing(_ notes: [NoteEvent], settings: GlobalSettings) -> [NoteEvent] {
        NoteFilter.apply(
            notes, minimumLength: settings.minimumNoteLength, minimumConfidence: settings.minimumConfidence)
    }
}
