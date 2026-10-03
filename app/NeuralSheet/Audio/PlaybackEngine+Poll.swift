import AVFoundation
import Foundation
import Synchronization

/// The 30 Hz poll on the main queue: the health check that rebuilds an engine that stopped on its
/// own, the count-in's hook, and the end of the take, which the render block only counts.
nonisolated extension PlaybackEngine {
    /// CoreAudio reshaping the graph under the engine — the default device changing, a device going
    /// away, the format the hardware settles on after a switch — stops the engine and invalidates
    /// its connections, sometimes a moment after the call that caused it returned. Rather than
    /// chasing the notification, the poll that watches for the end of the take also watches for an
    /// engine that should be running and is not, and rebuilds it.
    private func healIfNeeded() {
        guard shouldRun, !engine.isRunning, !isRebuilding,
            healAttempts < Self.healAttemptLimit,
            Date().timeIntervalSince(lastRebuild) > healDelay
        else { return }

        healAttempts += 1
        rebuildGraph {}

        if engine.isRunning {
            resetHealBudget()
        } else {
            // Backing off rather than hammering: an engine that cannot start is usually waiting on
            // hardware that is not coming back, and a full graph rebuild four times a second for
            // the rest of the session is worse than giving up and saying so.
            healDelay = Swift.min(healDelay * 2, Self.healBackoffMaxSeconds)

            if healAttempts >= Self.healAttemptLimit {
                healExhausted = true
                onHealExhausted?()
            }
        }
    }

    // Internal: start() starts it.
    func startWrapPoll() {
        wrapPoll?.cancel()
        lastWrapGeneration = state.wrapGeneration.load(ordering: .relaxed)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            self.healIfNeeded()
            self.onPoll?()

            let generation = self.state.wrapGeneration.load(ordering: .relaxed)
            guard generation != self.lastWrapGeneration else { return }

            self.lastWrapGeneration = generation

            // The current playhead, not 0: the block rewound to 0 when it wrapped, but up to 33 ms
            // have passed and a seek in that window has already moved the transport somewhere else.
            self.synthBank.scheduler.seek(toSeconds: self.playheadSeconds)
            self.synthBank.allNotesOff()
            self.synthBank.midiOut.panic()
            self.onPlayheadWrapped?()
        }
        timer.resume()
        wrapPoll = timer
    }
}
