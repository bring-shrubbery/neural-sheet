import AppKit
import NeuralSheetCore

/// The window's shortcuts (`NeuralNoteMainView::keyPressed`, inventory §11.2), as a local key
/// monitor rather than focus: the original view took keyboard focus for the whole window, so a
/// press reached it whatever control the pointer was last on.
///
/// | key | action |
/// |---|---|
/// | Space | play / pause |
/// | Shift + Space | go to start |
/// | Shift + Backspace | clear audio and transcription (`audioLoaded` or `populated` only) |
/// | r | record toggle |
/// | m | mute input toggle |
/// | c | centre playhead toggle |
/// | Esc | close the instrument picker |
///
/// A press while a text field has the keyboard is the field's; so is anything
/// with Command, Control or Option down, which are the menu bar's. Only the main window's own
/// events count: the Settings window, a menu panel or a sheet has the key when it is up, and a
/// Space meant for it must not start playback underneath. Escape goes to whichever popup is
/// open; the instrument picker listens for it itself, so it only has to be left alone here.
@MainActor final class KeyboardShortcuts {
    private let model: AppModel
    private var mainWindow: () -> NSWindow? = { nil }
    private var monitor: Any?

    private enum KeyCode {
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
    }

    init(model: AppModel) {
        self.model = model
    }

    /// - Parameter mainWindow: The window the shortcuts belong to; presses in any other are left
    ///   alone.
    func install(mainWindow: @escaping () -> NSWindow?) {
        guard monitor == nil else { return }

        self.mainWindow = mainWindow

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }

            return nil
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// True when the press was one of ours and has been acted on.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow(), window.attachedSheet == nil else { return false }

        // The field editor, while something is being typed.
        if window.firstResponder is NSText || window.firstResponder is NSTextField {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        guard modifiers.isSubset(of: [.shift]) else { return false }

        let shift = modifiers.contains(.shift)

        // A held key repeats; the original's transport toggled on every repeat too, but a Space
        // that flickers play and pause serves nobody.
        guard !event.isARepeat else { return false }

        switch event.keyCode {
        case KeyCode.space:
            if shift {
                model.goToStart()
            } else {
                model.togglePlay()
            }

            return true

        case KeyCode.backspace:
            guard shift else { return false }

            // The bin's states (`NnToolbar::updateEnablements`). Not while recording: clearing
            // mid-take would stop it behind the record button's back.
            if model.state == .audioLoaded || model.state == .populated {
                model.clear()
            }

            return true

        default:
            break
        }

        guard !shift, let characters = event.charactersIgnoringModifiers else { return false }

        // Lowercased: Caps Lock delivers "R" for the same key, and it is the key that is bound.
        switch characters.lowercased() {
        case "r":
            model.toggleRecord()
            return true

        case "m":
            model.inputMuted.toggle()
            return true

        case "c":
            model.followPlayhead.toggle()
            return true

        default:
            return false
        }
    }
}
