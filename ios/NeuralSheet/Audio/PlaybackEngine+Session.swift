import AVFoundation
import Foundation

/// The audio session (iOS app design §2): what iOS has where the Mac has devices. It is the
/// counterpart of the Mac's `applyDevices()`, so the shared ``start()`` configures and activates
/// it before the engine is prepared, every time; and it is watched for interruptions (a call, an
/// alarm, Siri) and route changes (headphones in or out, a Bluetooth device), which the Mac's HAL
/// listeners and health check cover there. Main thread.
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
        observeSessionIfNeeded()

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

    /// Gives the session back, telling whatever it interrupted that it may resume, and stops
    /// watching it.
    func deactivateSession() {
        sessionObservation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Interruptions and routes

    private func observeSessionIfNeeded() {
        guard sessionObservation == nil else { return }

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let observation = AudioSessionObservation()

        // The main queue: the session posts both on a thread of its own.
        observation.tokens = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                self?.handleInterruption(note.userInfo)
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
            ) { [weak self] note in
                self?.handleRouteChange(note.userInfo)
            },
        ]

        sessionObservation = observation
    }

    /// Pauses when the system takes the audio away, and stops the engine with the health check
    /// off, which would otherwise spend its retries against a session it cannot have. Starts
    /// again, and plays on if it was playing, only when the system says the interruption may
    /// resume; otherwise the next Play starts it.
    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let observation = sessionObservation,
            let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            observation.interruptedWhileRunning = shouldRun
            observation.interruptedWhilePlaying = isPlaying
            pause()
            stopEngine()

        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let wasRunning = observation.interruptedWhileRunning
            let wasPlaying = observation.interruptedWhilePlaying

            observation.interruptedWhileRunning = false
            observation.interruptedWhilePlaying = false

            guard options.contains(.shouldResume), wasRunning, !isShutDown else { return }

            try? start()
            if wasPlaying { play() }

        @unknown default:
            break
        }
    }

    /// Headphones pulled out pause the take rather than move it to the speaker, as iOS apps do;
    /// any route whose rate differs from the graph's rebuilds it, the transport surviving as it
    /// does a device change on the Mac.
    private func handleRouteChange(_ info: [AnyHashable: Any]?) {
        guard !isShutDown else { return }

        let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0

        if AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, isPlaying {
            pause()
        }

        rebuildIfRateChanged()
    }
}

/// The session observers and what an interruption stopped. Owned by the engine; going away
/// removes the observers, so no path leaves one registered.
nonisolated final class AudioSessionObservation: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    /// Whether the engine should run, and the take was playing, when the interruption began.
    var interruptedWhileRunning = false
    var interruptedWhilePlaying = false

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
