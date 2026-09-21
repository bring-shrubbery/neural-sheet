import AppKit

/// Quit and the Finder (projects design §5.4, §5.5). The model is handed over by the app's
/// `init`, before any delegate method can run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    /// The standalone quits with its last window, as the JUCE one did: closing the welcome
    /// window quits; closing the project window opens the welcome window first, so it is never
    /// the last.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q: the save-changes review when the project is edited, with the answer delivered later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.computeProjectEdited() else { return .terminateNow }

        model.reviewProject(then: {
            NSApp.reply(toApplicationShouldTerminate: true)
        }, cancelled: {
            NSApp.reply(toApplicationShouldTerminate: false)
        })

        return .terminateLater
    }

    /// A double-click on a `.neuralsheet` in the Finder, or a drop on the Dock icon. Opened at
    /// once when a window can show a failure; parked on the model until then (a launch by
    /// double-click), for the main view to pick up.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model,
            let url = urls.first(where: { $0.pathExtension.lowercased() == "neuralsheet" })
        else { return }

        if let show = model.showProjectWindow, model.presentError != nil {
            model.openProject(url: url)
            show()
        } else {
            model.pendingOpenURL = url
            model.showProjectWindow?()
        }
    }
}
