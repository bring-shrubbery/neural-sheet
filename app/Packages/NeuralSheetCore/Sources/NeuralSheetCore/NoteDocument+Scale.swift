import Foundation

/// The scale command (key design §3).
extension NoteDocument {
    /// Every melodic note among `ids` to the nearest pitch of `key`'s scale, a note between two
    /// degrees going to the lower; drums are left where they are. "Snap to Scale".
    public func snapToScale(_ ids: Set<NoteID>, key: MusicalKey) -> EditBatch {
        changing(notes.filter { ids.contains($0.id) && !$0.note.isDrum }, title: "Snap to Scale") { note in
            var note = note
            note.pitch = key.nearestScalePitch(note.pitch)
            return note
        }
    }
}
