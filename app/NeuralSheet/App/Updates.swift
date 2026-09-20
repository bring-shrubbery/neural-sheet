import Foundation
import Sparkle

/// The in-app updater. One Sparkle controller for the app's lifetime: it reads the feed named by
/// `SUFeedURL` in Info.plist on launch and then daily, shows its own dialogs, and installs on the
/// user's say-so. Views never see Sparkle; they go through ``AppModel/checkForUpdates()`` and
/// read ``canCheckForUpdates`` for the menu item.
@MainActor @Observable final class Updates {
    /// False while a check or an install is under way; the menu item is disabled then.
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // Sparkle drives its updater on the main thread, so the change lands on the main actor.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = change.newValue ?? false
            }
        }
    }

    /// Check for Updates…: Sparkle reports the outcome itself, including "You're up to date".
    func check() {
        controller.checkForUpdates(nil)
    }
}
