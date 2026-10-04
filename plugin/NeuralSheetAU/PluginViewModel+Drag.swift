import Foundation
import NeuralSheetCore

/// What the MIDI chip drags out (Audio Unit design §2, "UI"; the app's chip, MIDI out design §2):
/// the file the app's File → Export MIDI… or Export MusicXML… would write, by the same writers
/// (`ExportCommands`), at the host's tempo so the notes land on its bars, named after the host's
/// track. The bytes are made when the receiver asks for the file.
extension PluginViewModel {
    /// Whether there is a finished transcription to drag.
    var canDrag: Bool {
        !transcription.isRunning && !transcription.notes.isEmpty
    }

    /// One file for the chip's drag: its name and, asked for at drop time on the main actor, its
    /// bytes. Nil without a finished transcription.
    func dragExport(musicXML: Bool) -> (name: String, data: @MainActor () -> Data?)? {
        guard canDrag else { return nil }

        let name = PluginDragNames.fileName(contextName: trackName, musicXML: musicXML)

        return (name, { [weak self] in self?.dragData(musicXML: musicXML) })
    }

    /// The bytes as they are now: the notes, the strips' mix (each track's pan, none in the
    /// plugin) and the host's tempo.
    func dragData(musicXML: Bool) -> Data? {
        guard canDrag else { return nil }

        var editor = EditorState()
        if let tempo = playback.poll?.hostTempo {
            editor.grid = TempoGrid(bpm: TempoGrid.clampedBpm(tempo))
        }

        let notes = transcription.notes

        if musicXML {
            return ExportCommands.musicXMLData(notes: notes, ids: nil, editor: editor, arrangement: ScoreArrangement(),
                                               takeName: PluginDragNames.baseName(contextName: trackName))
        }

        return ExportCommands.midiData(notes: notes, editor: editor, mixer: playback.mixer, mode: overflowMode)
    }
}
