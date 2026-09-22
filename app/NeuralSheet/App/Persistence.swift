import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// The global settings (inventory §8.1): written on every change, and once more as the app
/// terminates, when the MIDI drag scratch is removed too. The session that used to be written
/// beside them is gone: a project file holds that now (`AppModel+Project.swift`).
extension AppModel {
    /// Writes every key (§8.1), so the file always lists what the app is using.
    func saveGlobalSettings() {
        try? paths.ensureDirectories()
        try? settings.save(to: paths.globalSettings)
    }
}

/// Keeps the settings file in step with the model. One per app, created beside the model.
@MainActor final class Persistence {
    private let model: AppModel
    private var terminateObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
    }

    /// Starts watching. Call once, when the first window appears.
    func start() {
        guard terminateObserver == nil else { return }

        Tooltips.enabled = model.settings.tooltipsVisible
        observeSettings()

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminate()
            }
        }
    }

    /// Whatever the observer below has not caught up with yet: the settings write is
    /// asynchronous, and the app is about to stop running the loop it is queued on.
    private func terminate() {
        model.saveGlobalSettings()
    }

    /// Every setter of `NnGlobalSettings` rewrote the file; here the file follows the struct.
    private func observeSettings() {
        withObservationTracking {
            _ = model.settings
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                Tooltips.enabled = self.model.settings.tooltipsVisible
                self.model.saveGlobalSettings()
                self.observeSettings()
            }
        }
    }
}
