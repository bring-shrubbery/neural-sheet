import Foundation

/// The alert texts several commands share (localization design §2), each written and commented
/// once for the string catalog. The wording is NeuralNote's where it had the message (inventory
/// §11.7), which is what the English entries stay.
extension AppModel {
    /// The title NeuralNote gave its plain failures.
    static var errorTitle: String {
        String(localized: "Error", comment: "Alert title: a plain failure, e.g. a file that could not be written")
    }

    static var deviceErrorTitle: String {
        String(localized: "Audio device could not be used", comment: "Alert title: CoreAudio refused an input or output device")
    }

    /// "CoreAudio error 'nope' (1852797029)." -- the status as `PlaybackEngine.describe` spells it.
    static func coreAudioError(_ status: String) -> String {
        String(localized: "CoreAudio error \(status).", comment: "Alert body: what CoreAudio said, e.g. \"CoreAudio error 'nope' (1852797029).\"")
    }

    /// The accepted formats after a file that would not load.
    static var checkFormatMessage: String {
        let formats = AudioFileLoader.acceptedFormatsList

        return String(localized: "Check your file format (Accepted formats: \(formats)).",
                      comment: "Alert body: a file that would not load; the formats are extensions, e.g. \"mp3, wav, …\"")
    }

    /// An unsaved project's name, in the window title and the save panel.
    static var untitled: String {
        String(localized: "Untitled", comment: "The window title and the save panel's name for a project not saved yet")
    }

    static var saveFailedTitle: String {
        String(localized: "Could not save the project.", comment: "Alert title: File → Save or Save As… failed")
    }

    static var transcriptionFailedTitle: String {
        String(localized: "Transcription failed.", comment: "Alert title: a run failed")
    }

    /// The model's failure, with its reason when there is one.
    static func transcriptionFailedBody(_ reason: String) -> String {
        reason.isEmpty
            ? String(localized: "The transcription model could not be loaded or run.", comment: "Alert body: a run failed without a reason")
            : String(localized: "The transcription model could not be loaded or run: \(reason).",
                     comment: "Alert body: a run failed; the reason is the engine's, or a sentence from this catalog")
    }
}
