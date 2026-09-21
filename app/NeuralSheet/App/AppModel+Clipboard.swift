import AppKit
import Foundation
import NeuralSheetCore

/// Cut, Copy and Paste for the selection: the notes go on the general pasteboard as JSON under a
/// type of our own, so the system's shortcuts and menu do what they do everywhere, and Paste puts
/// them down at the playhead with their spacing, pitches and instruments as they were.
extension AppModel {
    /// The pasteboard type the notes travel under. Ours alone: nothing else reads it.
    static let notesPasteboardType = NSPasteboard.PasteboardType("com.neuralsheet.notes")

    /// The selected notes, in document order, or nothing.
    private var selectedNotes: [NoteEvent] {
        guard let document, !editor.selection.isEmpty else { return [] }

        return document.notes.filter { editor.selection.contains($0.id) }.map(\.note)
    }

    /// True when the selection went on the pasteboard.
    @discardableResult
    func copySelection() -> Bool {
        let notes = selectedNotes

        guard workspace == .edit, !notes.isEmpty, let data = try? JSONEncoder().encode(notes) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: AppModel.notesPasteboardType)

        return true
    }

    /// A copy that then deletes, as one undo step.
    func cutSelection() {
        guard copySelection(), let document else { return }

        var batch = document.delete(editor.selection)
        batch.title = editor.selection.count == 1 ? "Cut Note" : "Cut Notes"
        commit(batch)
    }

    /// What the pasteboard holds for us, if anything.
    var pasteboardNotes: [NoteEvent]? {
        guard let data = NSPasteboard.general.data(forType: AppModel.notesPasteboardType),
              let notes = try? JSONDecoder().decode([NoteEvent].self, from: data), !notes.isEmpty
        else { return nil }

        return notes
    }

    /// The pasted notes land at the playhead, become the selection, and the first is heard.
    func paste() {
        guard workspace == .edit, var document, let notes = pasteboardNotes else { return }

        _ = dragCanceller?()

        let batch = document.paste(notes, at: playheadSeconds)
        replaceDocumentAndCommit(document, batch)
        setSelection(Set(batch.inserted.map(\.id)))
        auditionSelection()
    }
}
