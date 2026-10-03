import AVFoundation
import Foundation

/// The audio session (iOS app design §2): what iOS has where the Mac has devices. It is the
/// counterpart of the Mac's `applyDevices()`, so the shared ``start()`` configures and activates
/// it before the engine is prepared, every time. Main thread.
nonisolated extension PlaybackEngine {
    /// Play and record, out of the speaker rather than the receiver when nothing is plugged in,
    /// and to Bluetooth headphones as well as headsets.
    static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]

    /// Configures and activates the session, then makes sure the graph is at the rate it
    /// settled on: the engine was built against what the output node reported before the
    /// session was active. A failure is ``lastDeviceError``; the engine's own start then fails
    /// and the health check retries as it does on the Mac.
    func applyDevices() {
        guard !isShutDown else { return }

        lastDeviceError = nil

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            // The hardware's own rate, so nothing between the engine and the speaker resamples.
            try session.setPreferredSampleRate(session.sampleRate)
            try session.setActive(true)
        } catch {
            lastDeviceError = OSStatus(truncatingIfNeeded: (error as NSError).code)
            return
        }

        rebuildIfRateChanged()
    }

    /// Rebuilds the graph when the output's rate is not the one it was built for. Not from inside
    /// a rebuild, which reads the rate itself.
    func rebuildIfRateChanged() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate

        guard rate > 0, rate != sampleRate, !isRebuilding else { return }

        resetHealBudget()
        rebuildGraph {}
    }

    /// Gives the session back, telling whatever it interrupted that it may resume.
    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
