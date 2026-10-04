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

    /// The last thing before the process goes: the audio aggregate and any process tap in it are
    /// destroyed by hand rather than left to the process's exit (system audio design §2).
    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutDownAudio()
    }

    /// A double-click on a `.neuralsheet` in the Finder, or a drop on the Dock icon. Opened at
    /// once when a window can show a failure; parked on the model until then (a launch by
    /// double-click), for the main view to pick up.
    ///
    /// The Audio Unit's *Open in NeuralSheet* arrives here too, as a `neuralsheet://open` URL: the
    /// package it names is moved into the Music folder first and then opened like any other.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model else { return }

        let projects = urls.compactMap { url -> URL? in
            if url.scheme?.lowercased() == HandoffURL.scheme { return model.adoptHandoff(url) }
            return url.pathExtension.lowercased() == "neuralsheet" ? url : nil
        }

        guard let url = projects.first else { return }

        if let show = model.showProjectWindow, model.presentError != nil {
            model.openProject(url: url)
            show()
        } else {
            model.pendingOpenURL = url
            model.showProjectWindow?()
        }
    }
}
