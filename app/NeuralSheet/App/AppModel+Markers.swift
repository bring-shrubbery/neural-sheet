import Foundation
import NeuralSheetCore

/// The section markers (markers and lyrics design §2, §4): names at times in seconds, flagged on
/// the ruler in both timeline tabs, printed as rehearsal marks on the score and written into both
/// exports. Like the key and the chords they are project state, not note edits: nothing here goes
/// on the undo stack or touches the document, and any change marks the project edited
/// (`ProjectContent.markers`).
extension AppModel {
    var markers: [Marker] { editor.markers }

    /// Markers need a take to sit on; a transcription is not needed, so the Transcribe tab can
    /// name the sections while listening.
    var canEditMarkers: Bool { state.canPlay }

    /// What the menu's Previous / Next Marker ask: not the playhead, which the menu must not
    /// observe (it moves all through playback); past the last marker the item does nothing.
    var canSeekToMarkers: Bool { canEditMarkers && !editor.markers.isEmpty }

    // MARK: - Adding

    /// A marker at `seconds` named "Marker N", kept in order. Answers its id; one already at that
    /// spot is answered instead of doubled.
    @discardableResult
    func addMarker(at seconds: Double) -> UUID? {
        guard canEditMarkers else { return nil }

        var list = editor.markers

        guard let added = EditingCommands.addMarker(&list, at: seconds, duration: duration) else { return nil }

        if added.inserted {
            editMarkers { $0 = list }
        }

        return added.id
    }

    /// Edit → Markers → Add Marker at Playhead (⌥M): a marker where the playhead is, its card
    /// opened on the ruler so it can be named at once (issue #18, requirement 2). The Score tab
    /// has no ruler to open it on; the marker is added there all the same.
    func addMarkerAtPlayhead() {
        guard let id = addMarker(at: playheadSeconds) else { return }

        if workspace != .score {
            editor.markerToRename = id
        }
    }

    /// The timeline has opened the card the menu asked for.
    func markerRenameShown() {
        if editor.markerToRename != nil {
            editor.markerToRename = nil
        }
    }

    // MARK: - Editing

    /// The card's name field. A name left empty keeps the marker; the ruler shows its stem alone
    /// and the score and the exports leave it out.
    func renameMarker(id: UUID, to name: String) {
        guard let index = editor.markers.firstIndex(where: { $0.id == id }), editor.markers[index].name != name else { return }

        editMarkers { $0[index].name = name }
    }

    /// A drag on the ruler: the marker to `seconds`, the list kept in order.
    func moveMarker(id: UUID, to seconds: Double) {
        var list = editor.markers

        guard EditingCommands.moveMarker(&list, id: id, to: seconds, duration: duration) else { return }

        editMarkers { $0 = list }
    }

    /// The card's Delete.
    func removeMarker(id: UUID) {
        guard editor.markers.contains(where: { $0.id == id }) else { return }

        editMarkers { $0.removeAll { $0.id == id } }
    }

    // MARK: - Navigation

    /// ⌥⌘←: the playhead to the marker before it (issue #18, requirement 4).
    func seekToPreviousMarker() {
        guard canEditMarkers, let marker = editor.markers.marker(before: playheadSeconds) else { return }

        seek(toSeconds: marker.seconds)
    }

    /// ⌥⌘→: the playhead to the marker after it.
    func seekToNextMarker() {
        guard canEditMarkers, let marker = editor.markers.marker(after: playheadSeconds) else { return }

        seek(toSeconds: marker.seconds)
    }

    /// A double-click on a flag: the range from the marker to the next one, or to the end of the
    /// take, so Loop then repeats the section (issue #18, requirement 3).
    func markRange(fromMarker id: UUID) {
        guard let section = EditingCommands.section(from: id, in: editor.markers, duration: duration) else { return }

        setRange(section)
    }

    // MARK: - Helpers

    /// Every change goes through here, so the list stays in time order.
    private func editMarkers(_ change: (inout [Marker]) -> Void) {
        var list = editor.markers
        change(&list)
        editor.markers = list.sortedMarkers()
    }
}
