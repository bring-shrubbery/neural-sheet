import Foundation
import NeuralSheetCore

/// A MIDI file over the take (MIDI import design §2, §4; sub-issue I), as the Mac's
/// `AppModel+MIDIImport` lands it: as the transcription when there is none yet, or -- after the
/// Replace / Add question -- as one undoable edit when there is. Reading and refusing are the
/// shared `MIDIImportCommands`; a project is a take plus its notes, so a take must be under it.
extension MobileModel {
    /// A file read whole and waiting on the question: its name for the dialog and its notes.
    struct PendingMIDIImport: Identifiable, Equatable {
        let id = UUID()
        let fileName: String
        let notes: [NoteEvent]
    }

    /// A take to lay the notes over, and nothing in flight that owns the notes or the take.
    var canImportMIDI: Bool { source != nil && run == nil && recording == nil && !isImporting }

    /// A dropped or picked `.mid`. Without a take the file is refused with the Mac's reason; a
    /// file that cannot be read, or has no notes, says so and changes nothing. Read whole before
    /// anything is touched.
    func importMIDI(url: URL) {
        guard source != nil else {
            if canImport {
                alert = MobileAlert(title: MIDIImportCommands.failedTitle, message: MIDIImportCommands.needsTakeMessage)
            }
            return
        }

        guard canImportMIDI else { return }

        switch MIDIImportCommands.read(url: url) {
        case let .failure(refusal):
            alert = MobileAlert(title: MIDIImportCommands.failedTitle, message: refusal.message)

        case let .success(file):
            if document == nil {
                landMIDIAsTranscription(file)
            } else {
                exports.pendingMIDI = PendingMIDIImport(fileName: url.lastPathComponent, notes: file.allNotes)
            }
        }
    }

    /// The question's answer: Replace or Add, or nil for Cancel.
    func resolveMIDIImport(replacing: Bool?) {
        guard let pending = exports.pendingMIDI else { return }

        exports.pendingMIDI = nil

        // The question was asynchronous: whatever it was asked over may have gone.
        guard let replacing, canEdit, var document else { return }

        _ = dragCanceller?()

        let batch = document.importing(pending.notes, replacing: replacing)
        replaceDocumentAndCommit(document, batch)
        setSelection(Set(batch.inserted.map(\.id)))
    }

    /// An untranscribed take: the file's notes land the way a finished run's do. The selection
    /// was a constraint for a run that never happened, so it goes back to Automatic; the mix
    /// starts neutral, as a run's does; the file's tempo becomes the grid's over a grid nobody
    /// has set. One undo puts the take back without notes.
    private func landMIDIAsTranscription(_ file: MidiFile) {
        let before = projectSnapshot()

        if let grid = MIDIImportCommands.adoptedGrid(from: file, over: editor.grid) {
            editor.grid = grid
        }

        selectedGroups = []
        mixer.resetStoredSettings()
        installDocument(rawNotes: file.allNotes)
        registerUndo(String(localized: "Import MIDI", comment: "A version's name: \"Before Import MIDI — 14:02\""), before: before)
    }
}
