import SwiftUI

/// How a control is being interacted with. Every primitive derives its colours from one of these
/// (`nn::ControlState`).
nonisolated struct ButtonVisualState: Hashable, Sendable {
    var isHovered: Bool = false
    var isPressed: Bool = false
    var isOn: Bool = false
    var isEnabled: Bool = true
}

/// The one button in the UI: a flat rounded rectangle carrying an icon, a label, or both
/// (`NnFlatButton`).
///
/// Covers the transport row, the toolbar, the instrument strips' M/S pair, the sidebar's "+" and
/// the settings button -- they differ only in colours, corner radius and content, so those come in
/// as parameters rather than as subclasses.
///
/// Hover, pressed and disabled are never separate colours; they are derived from the idle and "on"
/// colours by `Theme.surface` / `Theme.foreground`, so every button in the window reacts alike. The
/// label closure is handed the live state so a label that needs more than a tint can read it.
struct FlatButton<Label: View>: View {
    private let isOn: Bool
    private let isEnabled: Bool
    private let idle: Color
    private let on: Color
    private let foregroundIdle: Color
    private let foregroundOn: Color
    private let corner: CGFloat
    private let action: () -> Void
    private let label: (ButtonVisualState) -> Label

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var size: CGSize = .zero

    init(isOn: Bool = false,
         isEnabled: Bool = true,
         idle: Color,
         on: Color,
         corner: CGFloat,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping (ButtonVisualState) -> Label) {
        self.init(isOn: isOn,
                  isEnabled: isEnabled,
                  idle: idle,
                  on: on,
                  foregroundIdle: Theme.textIcon,
                  foregroundOn: Theme.textPrimary,
                  corner: corner,
                  action: action,
                  label: label)
    }

    /// The same button with its own foreground pair, for the buttons whose label is not an idle
    /// icon -- the toolbar's `textButton` / `textBright`, the record button's `recIdle` / `rec`.
    init(isOn: Bool = false,
         isEnabled: Bool = true,
         idle: Color,
         on: Color,
         foregroundIdle: Color,
         foregroundOn: Color,
         corner: CGFloat,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping (ButtonVisualState) -> Label) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.idle = idle
        self.on = on
        self.foregroundIdle = foregroundIdle
        self.foregroundOn = foregroundOn
        self.corner = corner
        self.action = action
        self.label = label
    }

    private var state: ButtonVisualState {
        ButtonVisualState(isHovered: isEnabled && isHovered,
                          isPressed: isEnabled && isPressed,
                          isOn: isOn,
                          isEnabled: isEnabled)
    }

    var body: some View {
        let state = self.state
        let shape = RoundedRectangle(cornerRadius: corner, style: .circular)

        let surface = Theme.surface(idle: idle,
                                    on: on,
                                    isOn: state.isOn,
                                    isHovered: state.isHovered,
                                    isPressed: state.isPressed,
                                    isEnabled: state.isEnabled)

        let foreground = Theme.foreground(idle: foregroundIdle,
                                          on: foregroundOn,
                                          isOn: state.isOn,
                                          isHovered: state.isHovered)

        label(state)
            .foregroundStyle(foreground)
            .background(shape.fill(surface))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Theme.disabledAlpha)
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .onHover { hovering in
                isHovered = hovering
            }
            // A button whose own action disables it -- Transcribe, Record -- has the gesture masked
            // out from under a live press, so onEnded never arrives to clear it. Without this the
            // pressed surface comes back the moment the button is enabled again.
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isPressed = false
                    isHovered = false
                }
            }
            .gesture(press, including: isEnabled ? .all : .subviews)
            .pointerStyle(isEnabled ? .link : nil)
            .accessibilityAddTraits(.isButton)
    }

    /// A drag of zero distance rather than a tap, so the pressed surface appears on mouse-down and
    /// survives the pointer wandering -- and so releasing outside the button cancels, which is what
    /// every other button on the platform does.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressed, isEnabled {
                    isPressed = true
                }
            }
            .onEnded { value in
                isPressed = false

                if isEnabled, CGRect(origin: .zero, size: size).contains(value.location) {
                    action()
                }
            }
    }
}
