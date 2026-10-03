/// The coarse lifecycle state of the app, driving which controls are available.
public enum AppState: String, Codable, Sendable {
    /// No audio has been recorded or loaded yet.
    case empty
    /// Record was pressed with a count-in: the click is counting the bars in and the recorder
    /// starts on the downbeat after them (click design §2). Nothing is captured yet.
    case countingIn
    /// Audio is currently being captured from the input device.
    case recording
    /// Audio is available but has not been transcribed yet.
    case audioLoaded
    /// Transcription is running; partial results may already exist.
    case processing
    /// Transcription finished and notes are available.
    case populated

    /// Whether the audio player can be started in this state.
    public var canPlay: Bool {
        switch self {
        case .audioLoaded, .processing, .populated: true
        case .empty, .countingIn, .recording: false
        }
    }

    /// Whether a transcription result exists (possibly still in progress).
    public var hasTranscription: Bool {
        switch self {
        case .processing, .populated: true
        case .empty, .countingIn, .recording, .audioLoaded: false
        }
    }
}
