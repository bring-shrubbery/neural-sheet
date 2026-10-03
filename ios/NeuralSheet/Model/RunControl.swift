import Foundation

/// The run's cancel, reachable from any thread: the engine's flag, the separator's abandon, the
/// thermal gate's release and the separation's wait. `@unchecked Sendable`: `cancelled` and
/// `separation` are guarded by `lock`; the rest are themselves thread-safe.
nonisolated final class RunControl: @unchecked Sendable {
    let gate: ThermalGate
    private let engine: TranscriptionEngine
    private let separator: StemSeparator
    private let lock = NSLock()
    private var cancelled = false
    private var pendingSeparation: SeparationWait?

    init(engine: TranscriptionEngine, separator: StemSeparator, gate: ThermalGate) {
        self.engine = engine
        self.separator = separator
        self.gate = gate
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var separation: SeparationWait? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pendingSeparation
        }
        set {
            lock.lock()
            pendingSeparation = newValue
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let separation = pendingSeparation
        lock.unlock()

        gate.cancel()
        engine.cancel()

        if let separation {
            separator.cancel()
            separation.resume(.success(nil))
        }
    }
}

/// The separator's reason, as an `Error` a `Result` can carry.
nonisolated struct SeparationMessage: Error {
    var text: String
}

/// A separation's continuation, resumed once: by its completion, or by a cancel, whichever is
/// first. `@unchecked Sendable`: guarded by `lock`.
nonisolated final class SeparationWait: @unchecked Sendable {
    typealias Value = Result<StemSeparator.Stems?, SeparationMessage>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resumed = false
    private var early: Value?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true

        guard let continuation else {
            early = value
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        continuation.resume(returning: value)
    }
}
