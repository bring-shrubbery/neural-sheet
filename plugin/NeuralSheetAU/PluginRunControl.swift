import Foundation

/// The run's cancel, reachable from any thread: the engine's flag, the separator's abandon and the
/// separation's wait (the iOS app's `RunControl`, without its thermal gate: a Mac does not pause
/// a run for heat). `@unchecked Sendable`: `cancelled` and `pendingSeparation` are guarded by
/// `lock`; the engine and the separator are themselves thread-safe.
nonisolated final class PluginRunControl: @unchecked Sendable {
    private let engine: TranscriptionEngine
    private let separator: StemSeparator
    private let lock = NSLock()
    private var cancelled = false
    private var pendingSeparation: PluginSeparationWait?

    init(engine: TranscriptionEngine, separator: StemSeparator) {
        self.engine = engine
        self.separator = separator
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var separation: PluginSeparationWait? {
        get { lock.withLock { pendingSeparation } }
        set { lock.withLock { pendingSeparation = newValue } }
    }

    func cancel() {
        let separation = lock.withLock {
            cancelled = true
            return pendingSeparation
        }

        engine.cancel()

        if let separation {
            separator.cancel()
            separation.resume(.success(nil))
        }
    }
}

/// The separator's reason, as an `Error` a `Result` can carry.
nonisolated struct PluginSeparationMessage: Error {
    var text: String
}

/// A separation's continuation, resumed once: by its completion or by a cancel, whichever is
/// first. `@unchecked Sendable`: guarded by `lock`.
nonisolated final class PluginSeparationWait: @unchecked Sendable {
    typealias Value = Result<StemSeparator.Stems?, PluginSeparationMessage>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resumed = false
    private var early: Value?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let early: Value? = lock.withLock {
            if let early = self.early { return early }
            self.continuation = continuation
            return nil
        }

        if let early {
            continuation.resume(returning: early)
        }
    }

    func resume(_ value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true

            guard let continuation = self.continuation else {
                early = value
                return nil
            }
            self.continuation = nil
            return continuation
        }

        continuation?.resume(returning: value)
    }
}
