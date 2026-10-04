import Foundation
import NeuralSheetCore

/// The transcription's exits as bytes and names, shared by the Mac's `AppModel` and the iPhone and
/// iPad's `MobileModel` (iOS app design §2, Exports; sub-issue I): File → Export MIDI…, Export
/// MusicXML… and Export PDF…'s files from the project's state, and the names every export writes
/// them under. Pure: the models decide when an export may run and where its file goes.
nonisolated enum ExportCommands {
    // MARK: - Names

    /// `<source>_NNTranscription.mid`, or `NNTranscription.mid` for a recorded take.
    static func midiFileName(takeName droppedFileName: String?) -> String {
        MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// `<source>_NNTranscription.musicxml`, or `NNTranscription.musicxml` for a recorded take.
    static func musicXMLFileName(takeName droppedFileName: String?) -> String {
        MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// The score's pages, named as the MIDI is.
    static func pdfFileName(takeName droppedFileName: String?) -> String {
        PDFExport.fileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// The take's name in the audio and stem files: the dropped file's, or the project's for a
    /// recorded take.
    static func takeName(droppedFileName: String?, projectName: String?) -> String {
        StemNames.sanitized(droppedFileName ?? projectName ?? "")
    }

    // MARK: - Bytes

    /// The MIDI file (§6.1): through the tempo map, a tempo and a meter at each change (tempo map
    /// design §2); the section markers in the conductor track (markers and lyrics design §2);
    /// each track's pan as CC 10 (click design §2).
    static func midiData(notes: [NoteEvent], editor: EditorState, mixer: InstrumentMixerState,
                         mode: MidiOverflowMode) -> Data {
        let pans = mixer.settings.mapValues(\.pan)

        return MidiFileWriter.data(notes: notes, grid: editor.grid, mode: mode, markers: editor.markers, pans: pans)
    }

    /// The score (MusicXML design §4): the notes quantized to the grid, the parts as the
    /// arrangement shows them, titled after the sheet or the take, with the chord symbols as
    /// harmony (chord symbols design §2) and the markers as rehearsal marks (markers and lyrics
    /// design §2).
    static func musicXMLData(notes: [NoteEvent], ids: [NoteID?]?, editor: EditorState,
                             arrangement: ScoreArrangement, takeName droppedFileName: String?) -> Data {
        MusicXMLWriter.data(notes: notes, ids: ids, grid: editor.grid, key: editor.key, arrangement: arrangement,
                            takeName: droppedFileName, chords: editor.chords, markers: editor.markers)
    }
}
