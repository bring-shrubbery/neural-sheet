import CoreAudio
import Foundation
import NeuralSheetCore

/// What a take records from (system audio design §2): a microphone, System Audio or one app,
/// chosen in Audio → Input or Settings → Audio, remembered across launches. A tap input records
/// exactly like a microphone; what is extra here is the system's audio recording permission,
/// whose refusal sends the input back to the last device, and an app that quits mid-take, which
/// ends it.
extension AppModel {
    /// How long a take on a tap waits for its first block before the tap is taken to have been
    /// refused: a tap that is running delivers blocks, silent or not, within a few I/O cycles.
    static let tapStartTimeout = 1.0

    /// What the Audio menu and Settings show as chosen: the engine's own, which it rolls back when
    /// an input refuses, so the menu re-reads it after every pick. nil is the system default.
    var recordingInput: RecordingInput? { engine.recordingInput }

    /// The Audio menu's Input pick, applied at once (spec §7 deviation 7). A device the engine
    /// could not use is rolled back and said so; System Audio or an app is first made once and
    /// thrown away, so a refused permission is met here, on the pick, rather than on Record.
    func setRecordingInput(_ input: RecordingInput?) {
        guard input != engine.recordingInput else { return }

        if let kind = input?.tapKind {
            do {
                try ProcessTap.create(kind: kind).destroy()
            } catch {
                presentTapFailure((error as? ProcessTap.Failure)?.status)
                return
            }
        }

        engine.recordingInput = input
        reportDeviceSwitch()
        rememberRecordingInput()
    }

    /// The remembered input, at launch, before the engine starts (issue #20 §6): a device by its
    /// UID, System Audio, or an app that is running now. Anything that is not here falls back to
    /// the system default with no dialog, and the setting is left as it was for the next launch.
    func restoreRecordingInput() {
        guard let setting = RecordingInputSetting(encoded: settings.recordingInput),
            let input = RecordingInput(setting: setting)
        else { return }

        engine.recordingInput = input
        noteDeviceInput()
    }

    // MARK: - Recording on a tap

    /// Just before the recorder is armed: an app that quit since it was chosen -- between takes,
    /// when no tap is watching it -- and has been started again is a new process, found again by
    /// its bundle id. One that is not running is left for the tap to fail on and say so, rather
    /// than the take quietly recording something else.
    func refreshTappedApp() {
        guard case .app(let bundleID, let pid, _) = engine.recordingInput,
            ProcessTap.processObject(pid: pid) == nil,
            let relaunched = RecordingInput(setting: .app(bundleID: bundleID))
        else { return }

        engine.recordingInput = relaunched
    }

    /// Straight after the recorder is armed: the engine could not make the tap the input asked
    /// for -- the permission refused, or the app gone -- and has rolled the input back to a
    /// device. The take is thrown away rather than recorded from that device, the failure is
    /// said, and the input goes back to the last device chosen. True when it did that.
    func abandonTakeOnRefusedTap(wanted: RecordingInput?) -> Bool {
        guard wanted?.tapKind != nil,
            engine.recordingInput != wanted || engine.lastTapError != nil
        else { return false }

        _ = recorder.stop()
        clearNow()

        presentTapFailure(engine.lastTapError ?? engine.lastDeviceError)
        fallBackToDeviceInput()
        return true
    }

    /// Once a take on a tap is under way: if the tap has delivered nothing at all after
    /// ``tapStartTimeout``, it never started -- what a refused permission can look like when the
    /// tap itself was made -- and the take is cleared, said, and the input sent back to the last
    /// device (system audio design §2). A tap delivering silence is recording, and is left alone.
    func watchTapStart() {
        guard engine.recordingInput?.tapKind != nil else { return }

        tapStartGeneration &+= 1
        let generation = tapStartGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapStartTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.tapStartGeneration,
                    self.state == .recording || self.state == .countingIn,
                    self.engine.recordingInput?.tapKind != nil,
                    !self.recorder.hasReceivedInput
                else { return }

                self.clearNow()
                self.presentSystemAudioDenied()
                self.fallBackToDeviceInput()
            }
        }
    }

    /// The tapped app quit (system audio design §2): a take stops with what it has, a count-in is
    /// cancelled, and the input goes back to the last device, since the process it named is gone.
    func handleTappedAppQuit() {
        switch state {
        case .recording:
            toggleRecord()
        case .countingIn:
            cancelCountIn()
        case .empty, .audioLoaded, .processing, .populated:
            break
        }

        fallBackToDeviceInput()
    }

    // MARK: - Shared

    /// The dialog for a tap that could not be made: the permission one for a refusal, the device
    /// one for anything else.
    private func presentTapFailure(_ status: OSStatus?) {
        if status == OSStatus(kAudioHardwareIllegalOperationError) {
            presentSystemAudioDenied()
        } else {
            showError(AppModel.deviceErrorTitle,
                      status.map { AppModel.coreAudioError(PlaybackEngine.describe($0)) } ?? "")
        }
    }

    func presentSystemAudioDenied() {
        showError(
            String(localized: "NeuralSheet needs permission to record system audio.", comment: "Alert title: System Audio refused"),
            String(localized: "Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then choose the input again.",
                   comment: "Alert body: System Audio refused"))
    }

    /// Back to the device that was chosen before System Audio or the app, or the system default.
    private func fallBackToDeviceInput() {
        let device = lastDeviceInput.map { RecordingInput.device($0) }

        guard engine.recordingInput != device else { return }

        engine.recordingInput = device
        rememberRecordingInput()
    }

    /// Writes the engine's input -- what is really in effect after any rollback -- to the global
    /// settings, and notes it as the device to fall back to when it is one.
    private func rememberRecordingInput() {
        settings.recordingInput = engine.recordingInput?.setting?.encoded ?? ""
        noteDeviceInput()
    }

    private func noteDeviceInput() {
        if engine.recordingInput?.tapKind == nil {
            lastDeviceInput = engine.recordingInput?.device
        }
    }
}
