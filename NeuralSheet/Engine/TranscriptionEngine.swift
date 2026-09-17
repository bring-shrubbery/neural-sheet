import Foundation

/// One transcribed note, as the engine reports it.
nonisolated struct EngineNote: Equatable, Sendable {
    var onset: Double
    var offset: Double
    var pitch: Int
    var program: Int
    var isDrum: Bool
}

/// What one chunk added to the transcription.
nonisolated struct EngineUpdate: Sendable {
    var newNotes: [EngineNote]
    /// Seconds: every note ending before this has been reported.
    var finalizedThrough: Double
    /// 0 to 1, non-decreasing.
    var progress: Float
}

/// A failure from the engine, carrying the C error code and its description.
nonisolated enum EngineError: Error {
    case load(code: Int32, message: String)
    case transcribe(code: Int32, message: String)
    case cancelled

    /// True when the checkpoint's format version is one this build cannot read.
    var isUnsupportedVersion: Bool {
        switch self {
        case let .load(code, _), let .transcribe(code, _):
            return code == Int32(NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION.rawValue)
        case .cancelled:
            return false
        }
    }
}

/// Drives the muscriptor.cpp engine through the C bridge on a dedicated thread.
///
/// One run at a time per instance: the model is loaded, used and freed within
/// a single `run`, so nothing survives it.
///
/// `@unchecked Sendable`: `cancelRequested` and `running` are guarded by `lock`,
/// and `updateHandler` is written before the transcription thread starts and
/// read only on it.
nonisolated final class TranscriptionEngine: @unchecked Sendable {
    /// Guards `cancelRequested` and `running`, which `cancel` and `isRunning`
    /// read from any thread.
    private let lock = NSLock()
    private var cancelRequested = false
    private var running = false

    /// Read only on the transcription thread: it is set before that thread
    /// starts and cleared on it once the run is over.
    private var updateHandler: (@Sendable (EngineUpdate) -> Bool)?

    /// True from `run` starting until the transcription thread is done; it is
    /// already false by the time `completion` runs.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Load the model, transcribe, free it, on a dedicated thread.
    ///
    /// - Parameters:
    ///   - modelPath: A muscriptor GGUF checkpoint.
    ///   - groups: Instrument groups to restrict decoding to; empty transcribes everything.
    ///   - samples16k: The whole signal, 16 kHz mono float32.
    ///   - onUpdate: Called on the transcription thread, **not** the main thread, once per
    ///     5 s chunk and once more at the end. Return `false` to cancel. Hop to the main
    ///     queue yourself for anything that touches UI.
    ///   - completion: Called on the transcription thread, **not** the main thread, with the
    ///     authoritative result. The model is always freed before it runs.
    ///
    /// Calling `run` while `isRunning` is a programmer error; it reports
    /// `EngineError.transcribe` with the invalid-argument code, on the calling thread.
    func run(modelPath: URL,
             groups: [Int32],
             samples16k: [Float],
             onUpdate: @escaping @Sendable (EngineUpdate) -> Bool,
             completion: @escaping @Sendable (Result<[EngineNote], EngineError>) -> Void) {
        lock.lock()
        if running {
            lock.unlock()
            assertionFailure("TranscriptionEngine.run while a run is in flight")
            let code = Int32(NSHEET_ERR_INVALID_ARGUMENT.rawValue)
            completion(.failure(.transcribe(code: code, message: Self.describe(code))))
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

    /// Ask the run in flight to stop. Safe from any thread; the flag is observed
    /// at the next chunk boundary, so the run ends within one chunk.
    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    /// Every named instrument group, in the engine's enumerator order.
    static func allGroups() -> [Int32] {
        let total = nsheet_all_groups(nil, 0)

        guard total > 0 else {
            return []
        }

        var groups = [Int32](repeating: 0, count: total)
        let written = groups.withUnsafeMutableBufferPointer { nsheet_all_groups($0.baseAddress, $0.count) }

        return Array(groups.prefix(written))
    }

    /// The MIDI program the model emits for `group`, or -1 for an unknown one.
    static func program(for group: Int32) -> Int32 {
        nsheet_program_for(group)
    }

    // MARK: - Transcription thread

    /// Runs on the transcription thread. The engine is freed on every path.
    private func loadAndTranscribe(modelPath: URL,
                                   groups: [Int32],
                                   samples16k: [Float]) -> Result<[EngineNote], EngineError> {
        var errorCode: Int32 = 0

        guard let engine = nsheet_load(modelPath.path, true, &errorCode) else {
            return .failure(.load(code: errorCode, message: Self.describe(errorCode)))
        }

        let result = transcribe(engine: engine, groups: groups, samples16k: samples16k)
        nsheet_free(engine)

        return result
    }

    private func transcribe(engine: OpaquePointer,
                            groups: [Int32],
                            samples16k: [Float]) -> Result<[EngineNote], EngineError> {
        if isCancelled {
            return .failure(.cancelled)
        }

        var notes: UnsafeMutablePointer<nsheet_note>?
        var count = 0

        // `ctx` is the unretained engine that started the run; it outlives the
        // call because `nsheet_transcribe` blocks this thread.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let trampoline: nsheet_progress_fn = { update, ctx in
            guard let update, let ctx else {
                return true
            }

            return Unmanaged<TranscriptionEngine>.fromOpaque(ctx).takeUnretainedValue().handle(update: update)
        }

        let status = samples16k.withUnsafeBufferPointer { samples in
            groups.withUnsafeBufferPointer { groups in
                nsheet_transcribe(engine,
                                  samples.baseAddress,
                                  samples.count,
                                  groups.baseAddress,
                                  groups.count,
                                  trampoline,
                                  context,
                                  &notes,
                                  &count)
            }
        }

        guard status == Int32(NSHEET_OK.rawValue) else {
            return .failure(status == Int32(NSHEET_ERR_CANCELLED.rawValue)
                ? .cancelled
                : .transcribe(code: status, message: Self.describe(status)))
        }

        defer { nsheet_free_notes(notes) }

        return .success(Self.notes(from: notes, count: count))
    }

    /// Called on the transcription thread by the C callback.
    private func handle(update: UnsafePointer<nsheet_update>) -> Bool {
        let converted = EngineUpdate(newNotes: Self.notes(from: update.pointee.new_notes, count: update.pointee.count),
                                     finalizedThrough: update.pointee.finalized_through,
                                     progress: update.pointee.progress)

        let keepGoing = updateHandler?(converted) ?? true

        return keepGoing && !isCancelled
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    private static func notes(from pointer: UnsafePointer<nsheet_note>?, count: Int) -> [EngineNote] {
        guard let pointer, count > 0 else {
            return []
        }

        return UnsafeBufferPointer(start: pointer, count: count).map {
            EngineNote(onset: $0.onset,
                       offset: $0.offset,
                       pitch: Int($0.pitch),
                       program: Int($0.program),
                       isDrum: $0.is_drum)
        }
    }

    private static func describe(_ code: Int32) -> String {
        guard let text = nsheet_describe_error(code) else {
            return "unknown error"
        }

        return String(cString: text)
    }
}
