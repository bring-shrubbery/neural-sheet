import Foundation
import NeuralSheetCore

/// File → Import MIDI… and a dropped `.mid` (MIDI import design §2, §4), the parts both models
/// share: which files are MIDI, reading one whole with the reason it was refused, and the grid
/// a file brings to a project nobody has set a tempo for. Each model lands the notes itself.
nonisolated enum MIDIImportCommands {
    /// The extensions a drop routes to the MIDI import rather than to the audio one.
    static let midiExtensions: Set<String> = ["mid", "midi"]

    static func isMIDI(_ url: URL) -> Bool {
        midiExtensions.contains(url.pathExtension.lowercased())
    }

    static var failedTitle: String {
        String(localized: "Could not import the MIDI file.", comment: "Alert title: File → Import MIDI… failed")
    }

    /// What a drop with no take under it is told.
    static var needsTakeMessage: String {
        String(localized: "Load or record audio first, then import a MIDI file over it.",
               comment: "Alert body: a MIDI file dropped with no take")
    }

    /// The file read whole, or why it was refused: unreadable, a format 2 file, or no notes.
    static func read(url: URL) -> Result<MidiFile, Refusal> {
        let file: MidiFile

        do {
            file = try MidiFileReader.read(url: url)
        } catch MidiFileReader.Error.unsupportedFormat(let format) {
            return .failure(Refusal(message: String(localized: "The file is a format \(format) MIDI file. NeuralSheet reads formats 0 and 1.",
                                                    comment: "Alert body: a type 2 MIDI file")))
        } catch {
            return .failure(Refusal(message: String(localized: "The file is not a MIDI file, or it is damaged.", comment: "Alert body: an unreadable MIDI file")))
        }

        guard !file.allNotes.isEmpty else {
            return .failure(Refusal(message: String(localized: "The file has no notes.", comment: "Alert body: a MIDI file without notes")))
        }

        return .success(file)
    }

    /// A refused file's message, for the alert under ``failedTitle``.
    struct Refusal: Error, Equatable {
        var message: String
    }

    /// The file's tempo and meter, or its whole map, become the grid's, but only over a grid
    /// nobody has set (MIDI import design §2): a project's own tempo is never overwritten. Tick 0
    /// is the start of the audio, so bar 1 is too. Nil when the grid stays as it is.
    static func adoptedGrid(from file: MidiFile, over grid: TempoGrid) -> TempoGrid? {
        guard grid == TempoGrid(), let segments = file.gridSegments() else { return nil }

        var adopted = grid
        adopted.replaceMap(segments, offsetSeconds: 0)
        return adopted
    }
}
