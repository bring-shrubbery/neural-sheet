import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// File → Import MIDI… and a dropped `.mid` (MIDI import design §2, §4): a file's notes laid over
/// the take, as the transcription when there is none yet, or as one undoable edit when there is.
/// A project is a take plus its notes, so there is always a take underneath.
extension AppModel {
    /// A take to lay the notes over, and nothing in flight that owns the notes or the take.
    var canImportMIDI: Bool {
        (state == .audioLoaded || state == .populated) && !jobActive && regionJob == nil && importJob == nil
    }

    // MARK: - Ways in

    /// File → Import MIDI… (⌥⌘I): a panel for one MIDI file.
    func importMIDI() {
        guard canImportMIDI else { return }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Import MIDI", comment: "File → Import MIDI…'s open panel")
        panel.message = String(localized: "Import MIDI", comment: "File → Import MIDI…'s open panel")
        panel.allowedContentTypes = [.midi]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        importMIDI(url: url)
    }

    /// The menu's file and a dropped one. Without a take the drop is refused with a reason; a
    /// file that cannot be read, or has no notes, says so and changes nothing (MIDI import design
    /// §2). The file is read whole before anything is touched.
    func importMIDI(url: URL) {
        guard state == .audioLoaded || state == .populated else {
            if state == .empty, importJob == nil {
                showError(MIDIImportCommands.failedTitle, MIDIImportCommands.needsTakeMessage)
            }
            return
        }

        guard canImportMIDI else { return }

        let file: MidiFile

        switch MIDIImportCommands.read(url: url) {
        case let .success(read): file = read
        case let .failure(refusal):
            showError(MIDIImportCommands.failedTitle, refusal.message)
            return
        }

        guard state == .populated, document != nil else {
            landAsTranscription(file)
            return
        }

        guard let presentMIDIImportChoice else { return }

        presentMIDIImportChoice(url.lastPathComponent) { [weak self] choice in
            // The question was asynchronous: whatever it was asked over may have gone.
            guard let self, choice != .cancel, canImportMIDI, state == .populated else { return }

            landAsEdit(file.allNotes, replacing: choice == .replace)
        }
    }

    // MARK: - Landings

    /// An untranscribed take: the file's notes land the way a finished run's do, so the Edit and
    /// Score tabs open up, the sidebar shows the file's instruments, and Save writes them with
    /// the take (its sample count is read from the take at save time). The instrument selection
    /// was a constraint for a run that never happened, and its placeholders would sit beside the
    /// file's instruments, so it goes back to Automatic; the mix starts neutral, as a run's does.
    private func landAsTranscription(_ file: MidiFile) {
        adoptGrid(from: file)

        selectedGroups = []
        resetMixerSettingsForLaunch()
        // Notes a clear set aside for a run are kept here too, so a file over a cleared take
        // loses no edits either (versions design §2).
        saveVersionBeforeRun(String(localized: "Import MIDI", comment: "A version's name: \"Before Import MIDI — 14:02\""))
        landTranscription(file.allNotes)
    }

    /// A transcribed take: Replace or Add as one undoable edit, the inserted notes selected so
    /// they can be moved or deleted as a group. The grid is the project's and is left alone.
    private func landAsEdit(_ notes: [NoteEvent], replacing: Bool) {
        guard canEdit, var document else { return }

        _ = dragCanceller?()

        let batch = document.importing(notes, replacing: replacing)
        replaceDocumentAndCommit(document, batch)
        setSelection(Set(batch.inserted.map(\.id)))
    }

    private func adoptGrid(from file: MidiFile) {
        guard let grid = MIDIImportCommands.adoptedGrid(from: file, over: editor.grid) else { return }

        editor.grid = grid
    }
}
