import Foundation
import NeuralSheetCore

/// The transport: play and pause, go to start, seek, the mirrors of the engine's playhead, and the
/// display-link tick that keeps them current.
extension AppModel {
    func togglePlay() {
        guard state.canPlay else { return }

        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }

        syncTransport()
    }

    /// Stop and rewind (§5.1). The timeline follows ``goToStartGeneration`` back to its left edge.
    func goToStart() {
        guard state.canPlay else { return }

        engine.stop()
        syncTransport()
        goToStartGeneration &+= 1
    }

    /// Ignored unless `0 <= seconds < duration`, as the engine has it.
    func seek(toSeconds seconds: Double) {
        guard state.canPlay else { return }

        engine.seek(seconds: seconds)
        syncTransport()
    }

    // Internal: the init installs it as the engine's wrap callback.
    func handlePlayheadWrapped() {
        // The engine has already stopped and rewound.
        syncTransport()
    }

    private func syncTransport() {
        let playing = engine.isPlaying
        let position = engine.playheadSeconds

        if playing != isPlaying {
            isPlaying = playing
        }

        if position != playheadSeconds {
            playheadSeconds = position
        }
    }

    // MARK: - Display link

    /// One frame: the transport mirrors, the live recording length and the meters. `dt` is the
    /// frame interval in seconds.
    func displayLinkTick(dt: Double) {
        syncTransport()

        if state == .recording {
            let seconds = recorder.durationSeconds

            if seconds != duration {
                duration = seconds
            }
        }

        advanceMeters(dt: dt)
    }
}
