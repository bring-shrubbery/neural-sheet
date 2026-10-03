import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// Settings → Audio → Sound bank (click design §2): the SoundFont or DLS file every synth plays
/// through, global and remembered across launches. Applied at launch and on every change; a bank
/// that will not load puts the setting back to System and says so once.
extension AppModel {
    /// The chosen bank's file name, or nil for the system's General MIDI set.
    var soundBankName: String? {
        settings.soundBankPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Choose…: an open panel for `.sf2` and `.dls`, then the bank applied at once.
    func chooseSoundBank() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sound Bank"
        panel.message = "Choose a SoundFont (.sf2) or DLS (.dls) file to play the MIDI through."
        panel.allowedContentTypes = ["sf2", "dls"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if let path = settings.soundBankPath {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        settings.soundBankPath = url.path
        applySoundBankSetting()
    }

    /// Reset: the system's General MIDI set.
    func resetSoundBank() {
        guard settings.soundBankPath != nil else { return }

        settings.soundBankPath = nil
        applySoundBankSetting()
    }

    /// Puts the setting on every synth. A missing or unreadable file, or one that is not a sound
    /// bank, falls back to the system's: the setting reverts to System and the dialog says so --
    /// once, since the setting no longer names the file.
    func applySoundBankSetting() {
        let url = settings.soundBankPath.map { URL(fileURLWithPath: $0) }

        guard case .failure = engine.synthBank.setSoundBank(url: url), let url else { return }

        settings.soundBankPath = nil
        presentSoundBankFailure(fileName: url.lastPathComponent)
    }

    /// Shown now when a window can show it, else kept for ``presentSoundBankFailureIfAny()``: at
    /// launch, and from the Settings window with no project window open.
    private func presentSoundBankFailure(fileName: String) {
        guard presentError != nil else {
            pendingSoundBankFailure = fileName
            return
        }

        showError("Could not load the sound bank.",
                  "\"\(fileName)\" could not be loaded as a SoundFont (.sf2) or DLS (.dls) file. "
                      + "NeuralSheet is using the system's General MIDI sounds instead.")
    }

    /// The failure a launch (or a window-less Settings change) could not show yet.
    func presentSoundBankFailureIfAny() {
        guard let fileName = pendingSoundBankFailure, presentError != nil else { return }

        pendingSoundBankFailure = nil
        presentSoundBankFailure(fileName: fileName)
    }
}
