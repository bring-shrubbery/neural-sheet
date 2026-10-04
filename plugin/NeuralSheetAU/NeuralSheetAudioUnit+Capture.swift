import AudioToolbox
import Foundation

/// The capture's commands on the unit (Audio Unit design §2, "Audio path"), main actor. The work
/// is ``CaptureSession``'s; the unit gives it the ring it allocated and the host's transport.
extension NeuralSheetAudioUnit {
    /// Record: starts capturing the input now. False when a capture already runs or the host has
    /// not allocated render resources yet.
    @MainActor @discardableResult
    func startCapture() -> Bool {
        capture.start()
    }

    /// Stop: ends the capture and returns the take, nil when nothing was captured; disarms when
    /// armed.
    @MainActor @discardableResult
    func stopCapture() -> CapturedTake? {
        capture.stop()
    }

    /// Arm: the capture starts on the host's next start and stops on its stop.
    @MainActor
    func arm() {
        capture.arm()
    }

    /// The last take, for the view.
    @MainActor
    var capturedTake: SourceAudio? {
        capture.capturedTake
    }

    @MainActor
    func makeCaptureSession() -> CaptureSession {
        CaptureSession(
            ring: { [weak self] in self?.captureRing },
            hostIsPlaying: { [weak self] in self?.hostTransportIsMoving() })
    }

    /// Whether the host's transport is moving, through `transportStateBlock`; nil when the host
    /// gives none. Main thread only, from the session's 30 Hz poll: never the render thread's.
    @MainActor
    private func hostTransportIsMoving() -> Bool? {
        guard let block = transportStateBlock else { return nil }

        var flags = AUHostTransportStateFlags()
        var position: Double = 0
        var cycleStart: Double = 0
        var cycleEnd: Double = 0

        guard block(&flags, &position, &cycleStart, &cycleEnd) else { return nil }

        return flags.contains(.moving)
    }
}
