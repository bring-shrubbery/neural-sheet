import Foundation

/// Holds a run between chunks while the device is hot (iOS app design §2, Background): at
/// `.serious` or `.critical` the engine's update callback waits here, on the transcription
/// thread, until the device has cooled or the run is cancelled. The engine reports once per 5 s
/// chunk, so a pause lands on a chunk boundary and costs nothing but time.
///
/// The wait is a semaphore, signalled when the thermal state changes and when the run is
/// cancelled, with a timeout as a backstop so a missed notification cannot hold a run for good.
///
/// The run's drain reads ``isPaused`` to say so on the screen and in the Live Activity.
///
/// `@unchecked Sendable`: `cancelled` and `paused` are guarded by `lock`; the semaphore and the
/// observer are thread-safe.
nonisolated final class ThermalGate: @unchecked Sendable {
    typealias StateProvider = @Sendable () -> ProcessInfo.ThermalState

    /// How long one wait lasts before the state is read again.
    static let recheckInterval: DispatchTimeInterval = .seconds(2)

    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    private let wake = DispatchSemaphore(value: 0)
    private let state: StateProvider
    private var observer: NSObjectProtocol?

    /// - Parameter state: The thermal state; the process's own outside tests.
    init(state: @escaping StateProvider = { ProcessInfo.processInfo.thermalState }) {
        self.state = state

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [wake] _ in
            wake.signal()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    /// The transcription thread, between chunks: returns at once when the device is cool,
    /// otherwise once it has cooled or the run is cancelled.
    func waitWhileHot() {
        while Self.isHot(state()), !isCancelled {
            setPaused(true)
            _ = wake.wait(timeout: .now() + Self.recheckInterval)
        }

        setPaused(false)
    }

    /// Any thread: lets a waiting run go, for good.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()

        wake.signal()
    }

    /// Wakes a waiting run to read the state again; the notification's job, and a test's.
    func recheck() {
        wake.signal()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }
}
