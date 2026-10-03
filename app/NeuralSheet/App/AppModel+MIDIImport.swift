import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// File → Import MIDI… and a dropped `.mid` (MIDI import design §2, §4): a file's notes laid over
/// the take, as the transcription when there is none yet, or as one undoable edit when there is.
/// A project is a take plus its notes, so there is always a take underneath.
extension AppModel {
    /// The extensions the drop routes here rather than to ``loadAudio(url:)``.
    static let midiExtensions: Set<String> = ["mid", "midi"]

    static func isMIDI(_ url: URL) -> Bool {
        midiExtensions.contains(url.pathExtension.lowercased())
    }

    /// A take to lay the notes over, and nothing in flight that owns the notes or the take.
    var canImportMIDI: Bool {
        (state == .audioLoaded || state == .populated) && !jobActive && regionJob == nil && importJob == nil
    }

    // MARK: - Ways in

    /// File → Import MIDI… (⌥⌘I): a panel for one MIDI file.
    func importMIDI() {
        guard canImportMIDI else { return }

        let panel = NSOpenPanel()
        panel.title = "Import MIDI"
        panel.message = "Import MIDI"
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
                showError(AppModel.midiImportFailedTitle, "Load or record audio first, then import a MIDI file over it.")
            }
            return
        }

        guard canImportMIDI else { return }

        let file: MidiFile

        do {
            file = try MidiFileReader.read(url: url)
        } catch MidiFileReader.Error.unsupportedFormat(let format) {
            showError(AppModel.midiImportFailedTitle,
                      "The file is a format \(format) MIDI file. NeuralSheet reads formats 0 and 1.")
            return
        } catch {
            showError(AppModel.midiImportFailedTitle, "The file is not a MIDI file, or it is damaged.")
            return
        }

        guard !file.allNotes.isEmpty else {
            showError(AppModel.midiImportFailedTitle, "The file has no notes.")
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

    private static let midiImportFailedTitle = "Could not import the MIDI file."

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

    /// The file's tempo and meter, or its whole map, become the grid's, but only over a grid
    /// nobody has set (MIDI import design §2): a project's own tempo is never overwritten. Tick 0
    /// is the start of the audio, so bar 1 is too.
    private func adoptGrid(from file: MidiFile) {
        guard editor.grid == TempoGrid(), let segments = file.gridSegments() else { return }

        editor.grid.replaceMap(segments, offsetSeconds: 0)
    }
}
