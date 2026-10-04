import Foundation
import NeuralSheetCore

/// What the MIDI chip on the Edit and Score toolbars drags out (MIDI out design §2): the file
/// File → Export MIDI… or Export MusicXML… would write, by the same writer and with the same name,
/// and the scratch folder it passes through on the way to the drop.
extension AppModel {
    /// One file for the chip's drag: its name and, asked for at drop time on the main actor, its
    /// bytes. Nil unless the transcription is finished, as for both exports.
    func dragExport(musicXML: Bool) -> (name: String, data: @MainActor () -> Data?)? {
        guard canExport else { return nil }

        if musicXML {
            return (musicXMLExportFileName(), { [weak self] in self?.musicXMLData() })
        }

        return (midiExportFileName(), { [weak self] in self?.midiData() })
    }

    /// `temporaryDirectory/NeuralSheet`, where each drag writes into a folder of its own
    /// (``MidiPromiseWriter/scratchFolder``).
    nonisolated static var dragScratchFolder: URL {
        MidiPromiseWriter.scratchFolder
    }

    /// Whatever a drag left behind -- one whose promise the receiver never asked for -- when the
    /// project closes and when the app quits.
    func removeDragScratch() {
        try? FileManager.default.removeItem(at: AppModel.dragScratchFolder)
    }
}
