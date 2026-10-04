import Foundation
import Observation
import Synchronization

/// The main thread's side of a capture (Audio Unit design §2, "Audio path"): Record, Arm and
/// Stop, the drain while the capture runs, and the take when it stops. The render block's side is
/// the ``CaptureRing``.
///
/// Record starts at once and runs until Stop. Arm waits for the host: a 30 Hz main-thread timer
/// polls the transport (through ``hostIsPlaying``, which the unit answers from its
/// `transportStateBlock`; the block is never called from the render thread), the first
/// stopped-to-playing edge starts the capture and the playing-to-stopped edge, or Stop, ends it.
/// Arming while the host already plays waits for the next start, as a punch-in would.
///
/// The same timer drains the ring into ``channels`` while capturing, which is what the elapsed
/// readout counts, and ends the capture at the ring's ten minutes or when the host reallocated the
/// ring for another format.
///
/// Free of AU types (design §3): the unit hands it the ring and the transport as closures.
/// Main actor; the timer is invalidated on every path out of a capture or an arm.
@Observable final class CaptureSession {
    enum Phase: Equatable {
        case idle
        /// Waiting for the host's transport to start.
        case armed
        /// Copying the host's audio; `followsTransport` when an arm started it, so the host's stop
        /// ends it.
        case capturing(followsTransport: Bool)
    }

    private(set) var phase = Phase.idle

    /// Frames drained so far in the running capture.
    private(set) var capturedFrames = 0

    /// The running capture's rate, the host's.
    private(set) var sampleRate: Double = 0

    /// Seconds captured so far, from the drained frames.
    var elapsed: Double { sampleRate > 0 ? Double(capturedFrames) / sampleRate : 0 }

    /// The last take, nil before the first stop and after ``clear()``.
    private(set) var take: CapturedTake?

    /// The last take as the app's type, what the view draws.
    var capturedTake: SourceAudio? { take?.source }

    /// The ring the unit allocated for the host's format, nil before it has.
    @ObservationIgnored private let ring: () -> CaptureRing?

    /// Whether the host's transport is moving, nil when the host gives no transport.
    @ObservationIgnored private let hostIsPlaying: () -> Bool?

    @ObservationIgnored private var active: CaptureRing?
    @ObservationIgnored private var channels: [[Float]] = []
    @ObservationIgnored private var overflowAtStart = 0
    @ObservationIgnored private var hostWasPlaying = false
    @ObservationIgnored private var timer: Timer?

    /// How often the transport is polled and the ring drained.
    static let pollInterval: TimeInterval = 1.0 / 30

    init(ring: @escaping () -> CaptureRing?, hostIsPlaying: @escaping () -> Bool?) {
        self.ring = ring
        self.hostIsPlaying = hostIsPlaying
    }

    // MARK: - Commands

    /// Record: starts capturing now. False when a capture is already running or the host has not
    /// allocated render resources yet. Disarms.
    @discardableResult
    func start() -> Bool {
        if case .capturing = phase { return false }

        return begin(followsTransport: false)
    }

    /// Arm: waits for the host's next start. Ignored unless idle.
    func arm() {
        guard phase == .idle else { return }

        hostWasPlaying = hostIsPlaying() ?? false
        phase = .armed
        startTimer()
    }

    /// Stop: ends the capture and returns its take (nil when nothing was captured), or disarms.
    @discardableResult
    func stop() -> CapturedTake? {
        switch phase {
        case .idle:
            return nil
        case .armed:
            phase = .idle
            stopTimer()
            return nil
        case .capturing:
            return finish()
        }
    }

    /// Forgets the last take.
    func clear() {
        take = nil
    }

    // MARK: - Polling

    /// One poll: the transport's edge while armed or following it, the drain while capturing.
    /// The timer's, and the tests'.
    func tick() {
        switch phase {
        case .idle:
            stopTimer()

        case .armed:
            let playing = hostIsPlaying() ?? false
            defer { hostWasPlaying = playing }

            if playing && !hostWasPlaying {
                begin(followsTransport: true)
            }

        case .capturing(let followsTransport):
            // The host reallocated for another format: the old ring stopped; keep what it gave.
            guard let active, ring() === active else {
                finish()
                return
            }

            drain(active)

            if capturedFrames >= active.capacityFrames {
                finish()
                return
            }

            if followsTransport {
                let playing = hostIsPlaying() ?? false
                defer { hostWasPlaying = playing }

                if !playing && hostWasPlaying {
                    finish()
                }
            }
        }
    }

    // MARK: - Capture

    @discardableResult
    private func begin(followsTransport: Bool) -> Bool {
        guard let ring = ring() else { return false }

        ring.prepareForCapture()
        active = ring
        channels = Array(repeating: [], count: ring.channels)
        capturedFrames = 0
        sampleRate = ring.sampleRate
        overflowAtStart = ring.overflowFrames.load(ordering: .relaxed)
        hostWasPlaying = followsTransport
        take = nil

        // Releasing, so the cleared start time and the emptied ring are what the render block's
        // acquiring load of the flag sees with it.
        ring.capturing.store(true, ordering: .releasing)
        phase = .capturing(followsTransport: followsTransport)
        startTimer()

        return true
    }

    private func drain(_ ring: CaptureRing) {
        let drained = ring.drain()

        guard let count = drained.first?.count, count > 0 else { return }

        for channel in channels.indices where channel < drained.count {
            channels[channel].append(contentsOf: drained[channel])
        }
        capturedFrames += count
    }

    /// Clears the flag, drains what is left and builds the take. A cycle that read the flag just
    /// before it cleared pushes after the drain; that one buffer is dropped with the next
    /// capture's ``CaptureRing/prepareForCapture()``.
    @discardableResult
    private func finish() -> CapturedTake? {
        stopTimer()
        phase = .idle

        guard let ring = active else { return nil }

        ring.capturing.store(false, ordering: .releasing)
        drain(ring)

        let dropped = ring.overflowFrames.load(ordering: .relaxed) - overflowAtStart
        let captured = CapturedTake.make(channels: channels, sampleRate: ring.sampleRate,
                                         startSampleTime: ring.firstSampleTime, droppedFrames: dropped)

        ring.releaseMemory()
        active = nil
        channels = []
        take = captured

        return captured
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
