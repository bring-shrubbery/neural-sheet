// Ported from muscriptor.cpp's cpp/include/muscriptor/transcriber.hpp options and
// cpp/include/muscriptor/error.hpp with cpp/src/error.cpp.

/// What a caller asks the model to look for.
public struct TranscribeOptions: Sendable {
    /// The groups to restrict the transcription to; empty leaves the model unconstrained.
    /// A selection both conditions the prefix and forbids the tokens outside it.
    public var instruments: [InstrumentGroup]

    /// Whether each chunk after the first is teacher-forced with the notes still open at
    /// its boundary, instead of letting the model predict its own prologue.
    public var preludeForcing: Bool

    public init(instruments: [InstrumentGroup] = [], preludeForcing: Bool = true) {
        self.instruments = instruments
        self.preludeForcing = preludeForcing
    }
}

/// How a checkpoint is brought up.
public struct LoadOptions: Sendable {
    /// Whether to run the transformer on the GPU. A false value, or a machine with no
    /// usable device, falls back to the CPU backend.
    public var useGPU: Bool

    public init(useGPU: Bool = true) {
        self.useGPU = useGPU
    }
}

/// What one chunk's completion adds to the transcription.
public struct TranscriptionUpdate: Sendable {
    /// The notes this update finalises; may be empty. They arrive one chunk late,
    /// because overlap trimming can still shorten a note against one starting in the
    /// next chunk. Each note is reported once and never changes, so concatenating
    /// every update reproduces the whole transcription.
    public var newNotes: [Note]

    /// Seconds. Every note whose offset is below this has been reported, and nothing is
    /// known about the signal beyond it. The one exception is a note the model never
    /// closes, which the end of the signal closes far behind this line.
    public var finalizedThrough: Double

    /// Fraction of the input consumed, 0 to 1.
    public var progress: Float
}

/// What can go wrong between loading a checkpoint and returning notes.
public enum TranscriberError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No file at the path the caller gave.
    case fileNotFound(String)

    /// Not a GGUF, or a GGUF missing tensors or metadata this architecture needs.
    case invalidCheckpoint(String)

    case unsupportedArchitecture(String)

    /// A muscriptor GGUF whose `muscriptor.format_version` this build does not read.
    case unsupportedCheckpointVersion(found: Int)

    case outOfMemory

    /// A chunk's conditioning prefix plus its teacher-forced prologue does not fit in
    /// the KV cache. Generation itself is clamped rather than overflowing.
    case contextOverflow

    /// The progress callback asked to stop.
    case cancelled

    /// Something in `TranscribeOptions` is not usable, e.g. an instrument that is not
    /// one of the named groups.
    case invalidArgument(String)

    /// A bug in the library, not a problem with the input.
    case internalError(String)

    /// The short, stable description the C++ `describe` returns, for logs. The payload
    /// stays out of it so the string is the same for every instance of a case.
    public var description: String {
        switch self {
        case .fileNotFound: return "checkpoint file not found"
        case .invalidCheckpoint: return "not a valid muscriptor GGUF checkpoint"
        case .unsupportedArchitecture: return "checkpoint architecture is not supported"
        case .unsupportedCheckpointVersion: return "checkpoint format version is not the one this build reads"
        case .outOfMemory: return "out of memory"
        case .contextOverflow: return "a chunk did not fit in the model context"
        case .cancelled: return "cancelled by the caller"
        case .invalidArgument: return "invalid transcribe options"
        case .internalError: return "internal error"
        }
    }
}
