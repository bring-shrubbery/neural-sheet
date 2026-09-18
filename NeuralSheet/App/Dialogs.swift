import AppKit

/// The message boxes (`NativeMessageBox::showMessageBoxAsync`, inventory §11.7): a title, a body
/// and an OK button, nothing else.
///
/// The model composes every one of the §11.7 strings itself and hands them here through
/// `AppModel.presentError`, which `MainView` installs at ``install(on:window:)`` -- so a dialog is
/// never raised before there is a window to raise it on. Presented as a sheet on the main window
/// when there is one, or as an app-modal alert otherwise; either way the call returns at once and
/// the failing operation has already cleaned up (spec §6).
@MainActor enum Dialogs {
    /// Points `model.presentError` at the window.
    static func install(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentError = { title, body in
            present(title: title, body: body, on: window())
        }
    }

    /// One alert. An empty body leaves the informative text out rather than drawing a blank line,
    /// as "Could not load the recorded audio sample." has none.
    static func present(title: String, body: String, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        // `NoIcon` in the original; AppKit always draws one, and the app's own is the least loud.
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let window, window.isVisible {
            // A second message while one is up queues behind it.
            alert.beginSheetModal(for: window)
        } else {
            // Deferred so the caller's own stack -- a save panel closing, a drag ending -- has
            // unwound before a modal session begins on top of it.
            DispatchQueue.main.async {
                alert.runModal()
            }
        }
    }
}
