import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The transcription's exits as files: File → Export MIDI… and File → Export MusicXML….
extension AppModel {
    // MARK: - MIDI

    /// The file bytes, or nil unless the transcription is finished (§6.1).
    func midiData() -> Data? {
        guard canExport else { return nil }

        // Through the tempo map: a tempo and a meter at each change (tempo map design §2).
        // The section markers in the conductor track (markers and lyrics design §2).
        // Each track's pan as CC 10 (click design §2).
        let pans = mixer.settings.mapValues(\.pan)

        return MidiFileWriter.data(notes: notes, grid: editor.grid, mode: settings.midiOverflowMode, markers: editor.markers,
                                   pans: pans)
    }

    /// `<source>_NNTranscription.mid`, or `NNTranscription.mid` for a recorded take.
    func midiExportFileName() -> String {
        MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// File → Export MIDI…: the dialog, which then calls ``exportMidi()``.
    func requestExport() {
        guard canExport else { return }

        isExportDialogPresented = true
    }

    /// The export dialog's Export…: a save panel titled "Export MIDI" in the Music folder, `.mid`
    /// only, the overwrite warning left on (§6.1).
    func exportMidi() {
        guard let data = midiData() else { return }

        let panel = NSSavePanel()
        // `message` is what the modern panel shows; `title` is kept for the accessibility name.
        panel.title = String(localized: "Export MIDI", comment: "File → Export MIDI…'s save panel")
        panel.message = String(localized: "Export MIDI", comment: "File → Export MIDI…'s save panel")
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = midiExportFileName()
        panel.allowedContentTypes = [.midi]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(AppModel.errorTitle, String(localized: "Could not write the MIDI file.", comment: "Alert body: File → Export MIDI… failed"))
        }
    }

    // MARK: - MusicXML

    /// The score as bytes, or nil unless the transcription is finished (MusicXML design §4):
    /// the notes quantized to the grid, the parts as the arrangement shows them, titled after
    /// the sheet or the take, with the chord symbols as harmony (chord symbols design §2) and the
    /// markers as rehearsal marks (markers and lyrics design §2).
    func musicXMLData() -> Data? {
        guard canExport else { return nil }

        return MusicXMLWriter.data(notes: notes, ids: document?.notes.map { Optional($0.id) }, grid: editor.grid,
                                   key: editor.key, arrangement: arrangement, takeName: droppedFileName,
                                   chords: editor.chords, markers: editor.markers)
    }

    /// `<source>_NNTranscription.musicxml`, or `NNTranscription.musicxml` for a recorded take.
    func musicXMLExportFileName() -> String {
        MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// File → Export MusicXML…: a save panel titled "Export MusicXML" in the Music folder, the
    /// MIDI exit's shape. No dialog: the tempo and the division are the Edit toolbar's.
    func exportMusicXML() {
        guard let data = musicXMLData() else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export MusicXML", comment: "File → Export MusicXML…'s save panel")
        panel.message = String(localized: "Export MusicXML", comment: "File → Export MusicXML…'s save panel")
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = musicXMLExportFileName()
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(AppModel.errorTitle, String(localized: "Could not write the MusicXML file.", comment: "Alert body: File → Export MusicXML… failed"))
        }
    }
}
