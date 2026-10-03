import AVFoundation
import Foundation

/// iOS's counterparts of the Mac's `PlaybackEngine+IOBuffer.swift` and the input-tap half of
/// `PlaybackEngine+Devices.swift`, which talk to the HAL and are left out of this target. The
/// audio session stands in for the device: it is what takes the buffer request and what the
/// input node records from. Main thread; nothing here is reachable from the render block.
nonisolated extension PlaybackEngine {
    // MARK: - I/O buffer

    /// Asks the session for ``requestedIOBufferFrames`` at the hardware rate. Advisory, as on the
    /// Mac: ``readIOBufferSize()`` reports what the session settled on.
    func requestIOBufferSize() -> OSStatus {
        let session = AVAudioSession.sharedInstance()
        let rate = session.sampleRate > 0 ? session.sampleRate : sampleRate

        do {
            try session.setPreferredIOBufferDuration(Double(Self.requestedIOBufferFrames) / rate)
            return noErr
        } catch {
            return OSStatus(truncatingIfNeeded: (error as NSError).code)
        }
    }

    /// Reads back the frame count the session settled on into ``ioBufferFrames``.
    @discardableResult
    func readIOBufferSize() -> Int {
        let session = AVAudioSession.sharedInstance()
        ioBufferFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())

        return ioBufferFrames
    }

    // MARK: - Input tap

    /// Puts the tap on or takes it off, and rebuilds the graph when that changed whether the input
    /// node is in use at all -- the Mac's reasoning: the I/O unit enables its input side when the
    /// engine starts, from whether anything pulls the input node.
    ///
    /// A route with no input (the simulator on a Mac without one, a session that has not been
    /// granted the microphone) reports a format of 0 Hz or no channels: no tap goes on, and the
    /// recorder reads that format and refuses the take.
    func refreshInputTap() {
        let wasInstalled = inputTapInstalled

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        defer {
            if inputTapInstalled != wasInstalled {
                // A no-op while a rebuild is already in flight, which is where this call came from.
                rebuildGraph {}
            }
        }

        guard let inputTap else { return }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // nil, as on the Mac: a route change settles after it is asked for, and an explicit format
        // that no longer matches the node's live one is an uncatchable exception out of `installTap`.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            inputTap(buffer, time)
        }
        inputTapInstalled = true
    }

    // MARK: - Teardown

    /// The engine stops for good and the session is given back to other apps. Nothing starts
    /// the engine after.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true

        stopEngine()

        // Directly, not through ``inputTap``, whose `didSet` would rebuild the graph.
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        deactivateSession()
    }
}
