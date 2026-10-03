import SwiftUI

/// Which of the window's custom controls holds the keyboard through Full Keyboard Access (a11y
/// design §2, keyboard access). The window's shortcut monitor reads it: while a control has the
/// focus, Space and Return press that control rather than the transport, as they do on any
/// focused button on the platform. With keyboard navigation off nothing ever takes the focus, so
/// the shortcuts behave exactly as they always have.
@MainActor enum KeyboardFocus {
    private static var focused: Set<UUID> = []

    static var controlHasFocus: Bool { !focused.isEmpty }

    static func set(_ id: UUID, focused isFocused: Bool) {
        if isFocused {
            focused.insert(id)
        } else {
            focused.remove(id)
        }
    }
}

/// Makes a gesture-driven control reachable with Tab and pressable with Space or Return, the way
/// a system button is (a11y design §2): focusable for activation only, so it takes the focus
/// only while Full Keyboard Access is on, and SwiftUI draws the system focus ring around it then.
/// A click never focuses it, so a user without keyboard navigation sees nothing new.
struct KeyboardActivation: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .focusable(isEnabled, interactions: .activate)
            .focused($isFocused)
            .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                guard isEnabled else { return .ignored }

                action()
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                KeyboardFocus.set(id, focused: focused)
            }
            .onDisappear {
                KeyboardFocus.set(id, focused: false)
            }
    }
}

extension View {
    /// Tab reaches this control and Space or Return presses it while Full Keyboard Access is on.
    func keyboardActivation(isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(KeyboardActivation(isEnabled: isEnabled, action: action))
    }

    /// A tap-driven row or label as VoiceOver and Full Keyboard Access see a button: a system
    /// button stands in for it in the accessibility tree, so it is announced as one, dimmed while
    /// it is disabled and selected while `isSelected`, and the keyboard can press it.
    func accessibleButton(_ title: Text, isEnabled: Bool = true, isSelected: Bool = false,
                          action: @escaping () -> Void) -> some View {
        keyboardActivation(isEnabled: isEnabled, action: action)
            .accessibilityRepresentation {
                Button(action: { if isEnabled { action() } }) { title }
                    .disabled(!isEnabled)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
    }
}
