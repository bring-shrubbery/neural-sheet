import AppKit

/// The message boxes (`NativeMessageBox::showMessageBoxAsync`, inventory §11.7): a title, a body
/// and an OK button, nothing else -- and the one two-button question the editor asks before
/// edits are thrown away (design §3.5).
///
/// The model composes every one of the §11.7 strings itself and hands them here through
/// `AppModel.presentError`, at ``install(on:window:)`` -- installed by `MainView` on its window,
/// and by the welcome view without one on a cold launch, so a failed open from there still says
/// so. Presented as a sheet on the main window when there is one, or as an app-modal alert
/// otherwise; either way the call returns at once and the failing operation has already cleaned
/// up (spec §6).
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

    /// Points `model.presentConfirm` at the window too.
    static func installConfirm(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentConfirm = { title, body, confirmTitle, completion in
            confirm(title: title, body: body, confirmTitle: confirmTitle, on: window(), completion: completion)
        }
    }

    /// A two-button question: the destructive choice first (so it reads as the action), Cancel as
    /// the default so Return is safe.
    static func confirm(title: String, body: String, confirmTitle: String, on window: NSWindow?,
                        completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning

        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            DispatchQueue.main.async {
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    /// Points `model.presentNumber` at the window.
    static func installNumber(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentNumber = { title, label, range, initial, suffix, completion in
            presentNumber(title: title, label: label, range: range, initial: initial, suffix: suffix,
                          on: window(), completion: completion)
        }
    }

    /// A number to enter (editor commands design §2): the label as the body, a field and a stepper
    /// that keep each other in step, the unit after them, OK (Return) and Cancel. An alert rather
    /// than a SwiftUI sheet, as the other questions are, so it needs no window plumbing. The
    /// completion runs only on OK, with the value clamped into `range`.
    static func presentNumber(title: String, label: String, range: ClosedRange<Int>, initial: Int, suffix: String,
                              on window: NSWindow?, completion: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = label
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let entry = NumberEntry(range: range, initial: initial, suffix: suffix)
        alert.accessoryView = entry.view
        alert.window.initialFirstResponder = entry.field

        // The entry is held by the completion until the alert is answered: it is the field's and
        // the stepper's target.
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }

            completion(entry.value)
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            DispatchQueue.main.async {
                finish(alert.runModal())
            }
        }
    }

    /// Points `model.presentSaveReview` and `model.presentRevert` at the window.
    static func installProjectDialogs(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentSaveReview = { title, completion in
            saveReview(title: title, on: window(), completion: completion)
        }
        model.presentRevert = { title, completion in
            revert(title: title, on: window(), completion: completion)
        }
    }

    /// AppKit's own save-changes question, with its button order: Save (Return), Cancel (Escape),
    /// Don't Save (⌘D).
    static func saveReview(title: String, on window: NSWindow?,
                           completion: @escaping (AppModel.SaveReviewChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the document “\(title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]

        let choice: (NSApplication.ModalResponse) -> AppModel.SaveReviewChoice = { response in
            switch response {
            case .alertFirstButtonReturn: .save
            case .alertThirdButtonReturn: .discard
            default: .cancel
            }
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(choice(response))
            }
        } else {
            DispatchQueue.main.async {
                completion(choice(alert.runModal()))
            }
        }
    }

    /// AppKit's own revert question: Revert, Cancel (Return, so a stray key is safe).
    static func revert(title: String, on window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to revert to the most recently saved version of “\(title)”?"
        alert.informativeText = "Your current changes will be lost."
        alert.alertStyle = .warning

        let revert = alert.addButton(withTitle: "Revert")
        revert.hasDestructiveAction = true
        revert.keyEquivalent = ""

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            DispatchQueue.main.async {
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}

extension Dialogs {
    /// Points `model.presentMIDIImportChoice` at the window.
    static func installMIDIImportChoice(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentMIDIImportChoice = { fileName, completion in
            midiImportChoice(fileName: fileName, on: window(), completion: completion)
        }
    }

    /// Import MIDI over a transcription (MIDI import design §2): Replace the notes (Return), Add
    /// to the notes, Cancel (Escape). Neither choice needs guarding behind Cancel as Discard
    /// does: both land as one edit that Undo takes back.
    static func midiImportChoice(fileName: String, on window: NSWindow?,
                                 completion: @escaping (AppModel.MIDIImportChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Import “\(fileName)”?"
        alert.informativeText = "The take already has a transcription. The file's notes can replace its notes or be added to them."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Replace the notes")
        alert.addButton(withTitle: "Add to the notes")
        alert.addButton(withTitle: "Cancel")

        let choice: (NSApplication.ModalResponse) -> AppModel.MIDIImportChoice = { response in
            switch response {
            case .alertFirstButtonReturn: .replace
            case .alertSecondButtonReturn: .add
            default: .cancel
            }
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(choice(response))
            }
        } else {
            DispatchQueue.main.async {
                completion(choice(alert.runModal()))
            }
        }
    }
}

/// The number alert's accessory: a whole-number field, a stepper and the unit, kept in step.
@MainActor private final class NumberEntry: NSObject {
    let view: NSStackView
    let field: NSTextField
    private let stepper: NSStepper
    private let range: ClosedRange<Int>

    init(range: ClosedRange<Int>, initial: Int, suffix: String) {
        self.range = range

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.positivePrefix = range.lowerBound < 0 ? "+" : ""

        field = NSTextField()
        field.formatter = formatter
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true

        stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false

        let unit = NSTextField(labelWithString: suffix)
        view = NSStackView(views: [field, stepper, unit])
        view.orientation = .horizontal
        view.spacing = 6

        super.init()

        let start = min(max(initial, range.lowerBound), range.upperBound)
        field.integerValue = start
        stepper.integerValue = start
        field.target = self
        field.action = #selector(fieldChanged)
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        view.setFrameSize(view.fittingSize)
    }

    /// What the field holds, clamped; the field wins over the stepper, since a typed number that
    /// has not been committed with Tab is still what the user meant.
    var value: Int {
        min(max(field.integerValue, range.lowerBound), range.upperBound)
    }

    @objc private func fieldChanged() {
        stepper.integerValue = value
    }

    @objc private func stepperChanged() {
        field.integerValue = stepper.integerValue
    }
}
