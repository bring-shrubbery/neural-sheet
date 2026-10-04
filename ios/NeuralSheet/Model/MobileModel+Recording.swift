import AVFoundation
import Darwin
import Foundation
import NeuralSheetCore

/// Recording a take (iOS app design §2, Imports): the microphone permission, the count-in and
/// Click while recording from the global settings, and the take installed when it stops. The
/// count-in is the Mac's (`AppModel+Click`): the recorder is armed against the click's downbeat,
/// so the take's first sample is the one heard on the downbeat, and the 30 Hz poll only moves the
/// screen from the count to the take.
extension MobileModel {
    enum RecordingState: Equatable {
        /// The count shown, "4", "3", "2", "1".
        case countingIn(remaining: Int)
        /// Seconds captured so far.
        case recording(seconds: Double)
    }

    /// How much take the recording's click list covers, as on the Mac.
    private static let recordingClickHorizon = 3600.0

    /// The Record button: starts a take, stops the one in progress, or cancels a count-in.
    func toggleRecord() {
        switch recording {
        case nil:
            guard canImport else { return }

            switch Recorder.microphoneAuthorization {
            case .authorized:
                beginRecording()

            case .notDetermined:
                // The answer arrives on the main queue (`Recorder.requestMicrophoneAccess`).
                Recorder.requestMicrophoneAccess { [weak self] granted in
                    MainActor.assumeIsolated {
                        guard let self, self.recording == nil, self.canImport else { return }

                        if granted {
                            self.beginRecording()
                        } else {
                            self.presentMicrophoneDenied()
                        }
                    }
                }

            default:
                presentMicrophoneDenied()
            }

        case .countingIn:
            cancelRecording()

        case .recording:
            stopRecording()
        }
    }

    /// Nothing kept: a count-in tapped away, or a document closing mid-take.
    func cancelRecording() {
        guard recording != nil else { return }

        recordingPoll?.cancel()
        recordingPoll = nil
        _ = recorder.stop()
        recording = nil
        endRecordingClick()
    }

    // MARK: - The take

    private func beginRecording() {
        do {
            try engine.start()
        } catch {
            alert = MobileAlert(title: Self.errorTitle, message: PlaybackEngine.describe(error))
            return
        }

        let settings = self.settings
        let aligned = settings.countInBars > 0 || settings.clickWhileRecording

        // Before the recorder is armed: a mark left from the last take would start it at once.
        if aligned {
            engine.synthBank.resetDownbeat()
        }

        do {
            try recorder.start(atDownbeat: aligned)
        } catch Recorder.RecordError.permissionDenied {
            presentMicrophoneDenied()
            return
        } catch {
            alert = MobileAlert(title: Self.errorTitle,
                                message: String(localized: "File creation for recording failed.", comment: "Alert body: the recording file could not be made"))
            return
        }

        if aligned {
            startCountIn(settings: settings)
        } else {
            recording = .recording(seconds: 0)
        }

        startRecordingPoll()
    }

    /// The click's list becomes the count-in (and the take's beats with Click while recording)
    /// and its clock starts; straight to the take with no count-in bars.
    private func startCountIn(settings: GlobalSettings) {
        let plan = ClickTrack.recording(grid: editor.grid, countInBars: settings.countInBars,
                                        clickDuringTake: settings.clickWhileRecording,
                                        horizon: Self.recordingClickHorizon)
        let bank = engine.synthBank

        countInBeats = plan.events.filter { $0.startTime < plan.seconds }.map(\.startTime)

        bank.setClickEvents(plan.events)
        bank.clickEnabled = true
        bank.startClickClock(downbeatSeconds: plan.seconds)

        if plan.seconds > 0 {
            recording = .countingIn(remaining: countInBeats.count)
        } else {
            beginTake()
        }
    }

    private func startRecordingPoll() {
        recordingPoll?.cancel()
        recordingPoll = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollRecording()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// 30 Hz: the count shown and the take begun once the downbeat's host time has passed (the
    /// recorder has already started itself then); during the take, the seconds captured.
    private func pollRecording() {
        switch recording {
        case .countingIn:
            let bank = engine.synthBank

            if let downbeat = bank.downbeat.hostTime, mach_absolute_time() >= downbeat {
                beginTake()
                return
            }

            let clock = bank.clickClockSeconds
            let started = countInBeats.count(where: { $0 <= clock })
            let remaining = max(1, countInBeats.count - max(started, 1) + 1)

            if recording != .countingIn(remaining: remaining) {
                recording = .countingIn(remaining: remaining)
            }

        case .recording:
            let seconds = (recorder.durationSeconds * 10).rounded(.down) / 10

            if recording != .recording(seconds: seconds) {
                recording = .recording(seconds: seconds)
            }

        case nil:
            break
        }
    }

    /// The downbeat: the take is under way, and the grid's bar 1 is its first sample.
    private func beginTake() {
        countInBeats = []
        editor.grid.offsetSeconds = 0
        recording = .recording(seconds: 0)
    }

    private func stopRecording() {
        recordingPoll?.cancel()
        recordingPoll = nil

        let take = recorder.stop()
        recording = nil
        endRecordingClick()

        guard let take else {
            // Nothing captured is not a failure; a take that could not be written or read back is.
            switch recorder.lastError {
            case .fileCreation:
                alert = MobileAlert(title: Self.errorTitle,
                                    message: String(localized: "File creation for recording failed.", comment: "Alert body: the recording file could not be made"))
            case .readBack, .writeFailed:
                alert = MobileAlert(title: String(localized: "Could not load the recorded audio sample.", comment: "Alert title: a finished take could not be read back"),
                                    message: "")
            case .permissionDenied:
                presentMicrophoneDenied()
            case nil:
                break
            }
            return
        }

        let before = projectSnapshot()
        installSource(take)
        registerUndo(String(localized: "Record", comment: "Undo menu: a take was recorded"), before: before)
        print("NeuralSheet record: \(String(format: "%.2f", take.duration)) s")
    }

    /// After a take or a cancelled count-in: the click back on the transport, the project's
    /// switch and the project's beats.
    private func endRecordingClick() {
        engine.synthBank.stopClickClock()
        countInBeats = []
        applyClickEnabled()
        refreshClickTrack()
    }

    private func presentMicrophoneDenied() {
        alert = MobileAlert(
            title: Self.errorTitle,
            message: String(localized: "Microphone access has not been granted. Allow NeuralSheet to use the microphone in Settings › Privacy & Security › Microphone.",
                            comment: "Alert body: recording without the microphone permission (iOS)"))
    }

    static var errorTitle: String {
        String(localized: "Error", comment: "Alert title: a plain failure, e.g. a file that could not be written")
    }
}
