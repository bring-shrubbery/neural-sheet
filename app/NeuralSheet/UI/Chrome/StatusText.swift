import NeuralSheetCore
import SwiftUI

/// What the status bar said, now the window's subtitle (native chrome design §4): the model in
/// use, the instrument and note counts, the pitch range and the take's length, each only once it
/// means something, and while a version is ghosted behind the roll how far the notes are from it.
enum StatusText {
    static let separator = "\u{00B7}"

    /// The figures, in reading order.
    static func segments(_ model: AppModel) -> [String] {
        let status = model.statusLine
        // The model in use first -- the top bar's Model button used to say it, and it is worth
        // knowing without opening Settings.
        let modelName = model.modelSize?.localizedName
            ?? String(localized: "None", comment: "Status bar: no transcription model installed")

        var segments: [String] = []

        // The take's file, which the Transcribe toolbar named.
        if let name = model.droppedFileName {
            segments.append(name)
        }

        segments.append(String(localized: "Model: \(modelName)", comment: "Status bar: the transcription model in use"))

        // An instrument can be selected before it has been transcribed, and its empty range would
        // otherwise read as "C-1 - C-1".
        if status.instruments > 0 || status.notes > 0 {
            segments.append(String(localized: "\(status.instruments) instruments", comment: "Status bar: how many instruments the transcription has"))
            segments.append(String(localized: "\(status.notes) notes", comment: "Status bar: how many notes the transcription has"))
        }

        if status.notes > 0, let lowest = status.lowest, let highest = status.highest {
            segments.append("\(TimeFormat.pitchName(lowest)) - \(TimeFormat.pitchName(highest))")
        }

        if model.duration > 0 {
            let seconds = Formats.seconds2(model.duration)

            segments.append(String(localized: "\(seconds) s", comment: "Status bar: the take's length in seconds"))
        }

        // Versions design §2: the notes the compared version lacks, and the reverse, by the same
        // matching Show Differences selects with.
        if let comparison = model.comparisonSummary {
            segments.append(String(localized: "\(comparison.added) added, \(comparison.missing) missing vs \(comparison.name)",
                                   comment: "Status bar: notes the transcription has that the compared version lacks, and the reverse"))
        }

        return segments
    }

    /// The segments on one line, as the subtitle shows them.
    static func subtitle(_ model: AppModel) -> String {
        segments(model).joined(separator: " \(separator) ")
    }
}
