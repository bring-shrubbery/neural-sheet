import ActivityKit
import Foundation

/// The Live Activity a transcription shows while it runs (iOS app design §2, Background): the
/// take's name, the percentage, and what the run is doing. Compiled into the app, which starts and
/// updates it, and into the widget extension, which draws it.
nonisolated struct TranscriptionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// 0…100.
        var percent: Int
        /// "Transcribing", "Separating stems", "Paused — cooling down", "Done".
        var status: String
    }

    /// The take's name, or the project's for a recording.
    var fileName: String
}
