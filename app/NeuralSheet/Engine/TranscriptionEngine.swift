import Foundation
import NeuralSheetEngine

/// One transcribed note, as the engine reports it.
nonisolated struct EngineNote: Equatable, Sendable {
    var onset: Double
    var offset: Double
    var pitch: Int
    var program: Int
    var isDrum: Bool
    /// How sure the model was of the tokens that opened the note, 0…1 (confidence design §2).
    var confidence: Double
}

/// What one chunk added to the transcription.
nonisolated struct EngineUpdate: Sendable {
    var newNotes: [EngineNote]
    /// Seconds: every note ending before this has been reported.
    var finalizedThrough: Double
    /// 0 to 1, non-decreasing.
    var progress: Float
}

/// A failure from the engine, carrying the library's error and saying which half it came from.
nonisolated enum EngineError: Error {
    case load(TranscriberError)
    case transcribe(TranscriberError)
    case cancelled

    /// True when the checkpoint's format version is one this build cannot read.
    var isUnsupportedVersion: Bool {
        switch self {
        case let .load(error), let .transcribe(error):
            if case .unsupportedCheckpointVersion = error {
                return true
            }

            return false
        case .cancelled:
            return false
        }
    }

    /// The library's own description of the failure, for a dialog or a log; empty for a cancel,
    /// which is not reported to the user.
    var message: String {
        switch self {
        case let .load(error), let .transcribe(error):
            return error.description
        case .cancelled:
            return ""
        }
    }
}

/// Drives the `NeuralSheetEngine` transcriber on a dedicated thread.
///
/// One run at a time per instance: the model is loaded, used and dropped within
/// a single `run`, so nothing survives it -- unless the instance was made with
/// `retainsModel`, as a headless batch makes it (batch and CLI design §2): then the
/// last checkpoint stays loaded for the next run on the same file, and goes with
/// the instance.
///
/// `@unchecked Sendable`: `cancelRequested`, `running` and `backend` are guarded by `lock`,
/// and `updateHandler` and `retained` are touched only on the transcription thread
/// (or before it starts), one run at a time, the runs ordered by `lock`.
nonisolated final class TranscriptionEngine: @unchecked Sendable {
    /// Guards `cancelRequested`, `running` and `backend`, which `cancel`, `isRunning`
    /// and `lastBackendName` read from any thread.
    private let lock = NSLock()
    private var cancelRequested = false
    private var running = false
    private var backend: String?

    /// Read only on the transcription thread: it is set before that thread
    /// starts and cleared on it once the run is over.
    private var updateHandler: (@Sendable (EngineUpdate) -> Bool)?

    /// Whether a loaded checkpoint outlives its run.
    private let retainsModel: Bool

    /// The checkpoint the last run loaded, kept when `retainsModel`.
    private var retained: (url: URL, transcriber: Transcriber)?

    init(retainsModel: Bool = false) {
        self.retainsModel = retainsModel
    }

    /// True from `run` starting until the transcription thread is done; it is
    /// already false by the time `completion` runs.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Load the model, transcribe, drop it, on a dedicated thread.
    ///
    /// - Parameters:
    ///   - modelPath: A muscriptor GGUF checkpoint.
    ///   - groups: Instrument groups to restrict decoding to; empty transcribes everything.
    ///   - samples16k: The whole signal, 16 kHz mono float32.
    ///   - onUpdate: Called on the transcription thread, **not** the main thread, once per
    ///     5 s chunk and once more at the end. Return `false` to cancel. Hop to the main
    ///     queue yourself for anything that touches UI.
    ///   - completion: Called on the transcription thread, **not** the main thread, with the
    ///     authoritative result. The model is always released before it runs.
    ///
    /// Calling `run` while `isRunning` is a programmer error; it reports
    /// `EngineError.transcribe` with an invalid-argument error, on the calling thread.
    func run(modelPath: URL,
             groups: [Int32],
             samples16k: [Float],
             onUpdate: @escaping @Sendable (EngineUpdate) -> Bool,
             completion: @escaping @Sendable (Result<[EngineNote], EngineError>) -> Void) {
        lock.lock()
        if running {
            lock.unlock()
            assertionFailure("TranscriptionEngine.run while a run is in flight")
            completion(.failure(.transcribe(.invalidArgument("a run is already in flight"))))
            return
        }
        running = true
        cancelRequested = false
        lock.unlock()

        updateHandler = onUpdate

        let thread = Thread { [self] in
            let result = loadAndTranscribe(modelPath: modelPath, groups: groups, samples16k: samples16k)

            updateHandler = nil

            lock.lock()
            running = false
            lock.unlock()

            completion(result)
        }

        thread.name = "NeuralSheet.Transcription"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The backend the last loaded checkpoint runs on ("Metal" or "CPU", the library's name),
    /// for a log line or a bug report; nil before the first load.
    var lastBackendName: String? {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    /// Ask the run in flight to stop. Safe from any thread; the flag is observed
    /// at the next chunk boundary, so the run ends within one chunk.
    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    /// Every named instrument group, in the engine's enumerator order.
    static func allGroups() -> [Int32] {
        NeuralSheetEngine.InstrumentGroup.allCases.map(\.rawValue)
    }

    /// The MIDI program the model emits for `group`, or -1 for an unknown one.
    static func program(for group: Int32) -> Int32 {
        guard let group = NeuralSheetEngine.InstrumentGroup(rawValue: group) else {
            return -1
        }

        return Int32(group.program)
    }

    // MARK: - Transcription thread

    /// Runs on the transcription thread. Unless it is retained, the transcriber goes out
    /// of scope on every path, so the checkpoint's mapping and the backend are gone
    /// before we return.
    private func loadAndTranscribe(modelPath: URL,
                                   groups: [Int32],
                                   samples16k: [Float]) -> Result<[EngineNote], EngineError> {
        // A selection the model does not name is the caller's bug, and it is cheaper to
        // catch it than the load is: report it before the checkpoint is even opened.
        let instruments = groups.compactMap(NeuralSheetEngine.InstrumentGroup.init(rawValue:))

        guard instruments.count == groups.count else {
            return .failure(.transcribe(.invalidArgument("an instrument group is not one the model names")))
        }

        let transcriber: Transcriber

        if let retained, retained.url == modelPath {
            transcriber = retained.transcriber
        } else {
            // Another checkpoint's weights go before this one's are mapped.
            retained = nil

            do {
                transcriber = try Transcriber(url: modelPath, options: LoadOptions(useGPU: true))
            } catch {
                return .failure(.load(Self.transcriberError(error)))
            }

            if retainsModel {
                retained = (modelPath, transcriber)
            }
        }

        lock.lock()
        backend = transcriber.backendName
        lock.unlock()

        return transcribe(with: transcriber, instruments: instruments, samples16k: samples16k)
    }

    private func transcribe(with transcriber: Transcriber,
                            instruments: [NeuralSheetEngine.InstrumentGroup],
                            samples16k: [Float]) -> Result<[EngineNote], EngineError> {
        if isCancelled {
            return .failure(.cancelled)
        }

        do {
            let notes = try transcriber.transcribe(samples: samples16k,
                                                   options: TranscribeOptions(instruments: instruments)) { update in
                self.handle(update: update)
            }

            return .success(notes.map(EngineNote.init(_:)))
        } catch TranscriberError.cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.transcribe(Self.transcriberError(error)))
        }
    }

    /// Called on the transcription thread by the library, once per chunk.
    private func handle(update: TranscriptionUpdate) -> Bool {
        let converted = EngineUpdate(newNotes: update.newNotes.map(EngineNote.init(_:)),
                                     finalizedThrough: update.finalizedThrough,
                                     progress: update.progress)

        let keepGoing = updateHandler?(converted) ?? true

        return keepGoing && !isCancelled
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    /// The library throws `TranscriberError` and nothing else; the fallback is there so a
    /// future case cannot become a crash.
    private static func transcriberError(_ error: any Error) -> TranscriberError {
        error as? TranscriberError ?? .internalError(String(describing: error))
    }
}

private extension EngineNote {
    /// The library's note as the app's: the same six fields.
    ///
    /// `nonisolated` because the conversion runs on the transcription thread; the target's
    /// default isolation would otherwise put an extension member on the main actor.
    nonisolated init(_ note: NeuralSheetEngine.Note) {
        self.init(onset: note.onset,
                  offset: note.offset,
                  pitch: note.pitch,
                  program: note.program,
                  isDrum: note.isDrum,
                  confidence: Double(note.confidence))
    }
}
