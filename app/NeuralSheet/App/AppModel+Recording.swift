import AVFoundation
import Foundation
import NeuralSheetCore

/// The Record toggle: the microphone permission, opening the take and stopping it, and the
/// messages a take that could not be made or read back ends with.
extension AppModel {
    /// The Record toggle: starts a take from empty, stops the one in progress. Anything else is
    /// not the button's to do.
    func toggleRecord() {
        switch state {
        case .empty:
            // A video's audio is on its way in: the take it becomes would replace the recording.
            guard importJob == nil else { return }

            switch Recorder.microphoneAuthorization {
            case .authorized:
                beginRecording()

            case .notDetermined:
                // The prompt stands for as long as the user leaves it; `start()` never waits on it.
                Recorder.requestMicrophoneAccess { [weak self] granted in
                    MainActor.assumeIsolated {
                        guard let self, self.state == .empty, self.importJob == nil else { return }

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

        case .recording:
            stopRecording()

        case .countingIn:
            // Record again during the count-in cancels it, without a take (issue #19 §9).
            cancelCountIn()

        case .audioLoaded, .processing, .populated:
            return
        }
    }

    /// Opens the take. `atDownbeat` is the count-in's and Click while recording's: the recorder
    /// is armed against the click's downbeat and the click's clock is started
    /// (`AppModel+Click.swift`); otherwise the take starts now, as it always did.
    func startRecording(atDownbeat: Bool = false) {
        // Before the recorder is armed: a mark left from the last take would start it at once.
        if atDownbeat {
            engine.synthBank.resetDownbeat()
        }

        refreshTappedApp()
        let wanted = engine.recordingInput

        do {
            try recorder.start(atDownbeat: atDownbeat)
        } catch Recorder.RecordError.permissionDenied {
            presentMicrophoneDenied()
            return
        } catch {
            clearNow()
            showError(AppModel.errorTitle, String(localized: "File creation for recording failed.", comment: "Alert body: the recording file could not be made"))
            return
        }

        // System Audio or an app the engine could not tap (`AppModel+RecordingInput.swift`).
        if abandonTakeOnRefusedTap(wanted: wanted) { return }

        duration = 0

        if atDownbeat {
            startCountIn()
        } else {
            transition(to: .recording)
        }

        watchTapStart()
    }

    private func stopRecording() {
        guard let take = recorder.stop() else {
            // Nothing captured is not a failure; a take that could not be written or read back is.
            if let error = recorder.lastError {
                presentRecordingFailure(error)
            }

            clearNow()
            return
        }

        installSource(take)
        endRecordingClick()
    }

    private func presentRecordingFailure(_ error: Recorder.RecordError) {
        switch error {
        case .fileCreation:
            showError(AppModel.errorTitle, String(localized: "File creation for recording failed.", comment: "Alert body: the recording file could not be made"))
        case .readBack, .writeFailed:
            showError(String(localized: "Could not load the recorded audio sample.", comment: "Alert title: a finished take could not be read back"), "")
        case .permissionDenied:
            presentMicrophoneDenied()
        }
    }

    func presentMicrophoneDenied() {
        showError(
            AppModel.errorTitle,
            String(localized: "Microphone access has not been granted. Allow NeuralSheet to use the microphone in System Settings › Privacy & Security › Microphone.",
                   comment: "Alert body: recording without the microphone permission"))
    }
}
