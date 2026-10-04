import Foundation
import Observation
import Synchronization

/// The host's transport, polled at 30 Hz on the main thread (Audio Unit design §2, "Playhead"), as
/// ``CaptureSession`` polls it for Arm: whether it moves goes into ``PluginTransport/hostPlaying``
/// for the render block, which never calls the host's blocks itself. The host starting pauses the
/// plugin's own transport (it would not be heard anyway); its starts and stops are handed on for
/// the MIDI's panic. The view reads the state from here.
///
/// Runs while the host renders: started from `allocateRenderResources`, stopped from
/// `deallocateRenderResources`, the timer invalidated on every way out. Free of AU types
/// (design §3): the unit hands it the host's state as a closure. Main actor.
@Observable final class PluginTransportPoll {
    /// What the host's blocks said at the last poll: whether the transport moves (nil when the
    /// host gives no transport) and the tempo (nil when it gives no musical context).
    struct HostState: Equatable {
        var playing: Bool?
        var tempo: Double?
    }

    /// Whether the host's transport moves.
    private(set) var hostPlaying = false

    /// Whether the plugin's own transport plays (the render block stops it at the take's end).
    private(set) var ownPlaying = false

    /// The host's tempo, for the dragged file's grid; nil when the host gives none.
    private(set) var hostTempo: Double?

    /// Whether a poll is running.
    private(set) var isRunning = false

    /// The host's transport started or stopped, or the plugin's own stopped at the take's end.
    @ObservationIgnored var onHostStart: (() -> Void)?
    @ObservationIgnored var onHostStop: (() -> Void)?
    @ObservationIgnored var onOwnStop: (() -> Void)?

    @ObservationIgnored private let transport: PluginTransport
    @ObservationIgnored private let hostState: () -> HostState
    @ObservationIgnored private var timer: Timer?

    static let pollInterval: TimeInterval = 1.0 / 30

    init(transport: PluginTransport, hostState: @escaping () -> HostState) {
        self.transport = transport
        self.hostState = hostState
    }

    func start() {
        guard timer == nil else { return }

        isRunning = true
        tick()

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

    /// Stops polling; the host is taken as stopped.
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        transport.hostPlaying.store(false, ordering: .relaxed)

        if hostPlaying {
            hostPlaying = false
            onHostStop?()
        }
    }

    /// One poll. The timer's, and the tests'.
    func tick() {
        let state = hostState()
        let playing = state.playing ?? false

        transport.hostPlaying.store(playing, ordering: .relaxed)

        if playing != hostPlaying {
            hostPlaying = playing

            if playing {
                transport.pause()
                onHostStart?()
            } else {
                onHostStop?()
            }
        }

        let own = transport.ownPlaying.load(ordering: .relaxed)

        if own != ownPlaying {
            ownPlaying = own
            if !own { onOwnStop?() }
        }

        if state.tempo != hostTempo {
            hostTempo = state.tempo
        }
    }

    /// The plugin's own transport changed from the view: shown at once, not at the next poll.
    func refreshOwn() {
        let own = transport.ownPlaying.load(ordering: .relaxed)
        if own != ownPlaying { ownPlaying = own }
    }
}
