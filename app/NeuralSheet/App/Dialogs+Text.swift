import AppKit

/// The text alert (versions design §2): Save Version… asks for a name the way By Interval… asks
/// for a number, out of `Dialogs.swift` to keep that file focused.
extension Dialogs {
    /// Points `model.presentText` at the window.
    static func installText(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentText = { title, label, initial, completion in
            presentText(title: title, label: label, initial: initial, on: window(), completion: completion)
        }
    }

    /// A line of text to enter: the label as the body, a field holding `initial` selected so
    /// typing replaces it, OK (Return) and Cancel. The completion runs only on OK.
    static func presentText(title: String, label: String, initial: String, on window: NSWindow?,
                            completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = label
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK", comment: "Alert button"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))

        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }

            completion(field.stringValue)
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            DispatchQueue.main.async {
                finish(alert.runModal())
            }
        }
    }
}
