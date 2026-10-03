import Foundation
import NeuralSheetCore

/// The output device the Audio menu picks, what a device that refused or an output that would not
/// start is said with, and the audio's shutdown at quit. The input is AppModel+RecordingInput.swift's.
extension AppModel {
    /// What the Audio menu shows as chosen: the engine's own, which it rolls back when a device
    /// refuses, so the menu re-reads it after every pick. The input is ``recordingInput``
    /// (`AppModel+RecordingInput.swift`).
    var outputDevice: AudioDevice? { engine.outputDevice }

    /// The Audio menu's Output pick, applied at once (spec §7 deviation 7). A device the engine
    /// could not use is rolled back and said so.
    func setOutputDevice(_ device: AudioDevice?) {
        guard device != engine.outputDevice else { return }

        engine.outputDevice = device
        reportDeviceSwitch()
    }

    /// The pick rebuilt the graph and, when the engine was not running, was its retry: a device
    /// that refused is one dialog, an output that then would not start is the other.
    func reportDeviceSwitch() {
        if let status = engine.lastDeviceError {
            showError(AppModel.deviceErrorTitle, AppModel.coreAudioError(PlaybackEngine.describe(status)))
        } else if !engine.isRunning, engine.lastStartError != nil {
            presentAudioStartFailure()
        }
    }

    /// The app is quitting: the engine stops for good, and the aggregate and any tap in it are
    /// destroyed now (system audio design §2). From `applicationWillTerminate`.
    func shutDownAudio() {
        engine.shutDown()
    }

    /// Once, when the window can show a dialog: a launch whose output would not open -- and that
    /// the health check has not opened since -- is said so. Its retries carry on underneath.
    func presentAudioStartFailureIfAny() {
        guard !hasReportedLaunchStartFailure, !engine.isRunning,
              engine.lastStartError != nil || engine.healExhausted
        else { return }

        hasReportedLaunchStartFailure = true
        presentAudioStartFailure()
    }

    /// "Audio could not start", with what CoreAudio said. Not before a window exists: the launch
    /// path picks it up in ``presentAudioStartFailureIfAny()`` instead.
    // Internal: the init installs it as the engine's give-up callback.
    func presentAudioStartFailure() {
        guard presentError != nil else { return }

        let detail = engine.lastStartError.map { PlaybackEngine.describe($0) + "." }
            ?? String(localized: "The audio output did not start.", comment: "Alert body: the output device would not start, with no error to say why")

        showError(String(localized: "Audio could not start", comment: "Alert title: the audio output would not start"), detail)
    }
}
