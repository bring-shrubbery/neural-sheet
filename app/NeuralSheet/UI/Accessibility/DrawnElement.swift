import AppKit

/// Something a custom view draws rather than holds -- a note, a flag, a chord symbol, a staff
/// system -- as VoiceOver sees it (a11y design §2). Every reading is asked of closures when
/// VoiceOver asks, so an element made once stays right while the view scrolls, zooms or
/// repaints: the owning view only has to make new ones when *which* things it draws changes.
///
/// The frame is in the owning view's coordinates; the element converts it to the screen itself.
final class DrawnElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let rect: () -> CGRect?
    private let label: () -> String

    /// Read for VoiceOver's value, after the label.
    var value: (() -> String?)?
    /// VoiceOver's press; nil makes the element read-only.
    var press: (() -> Bool)?
    var isSelected: () -> Bool = { false }
    /// The named actions VoiceOver lists in its actions menu.
    var actions: () -> [NSAccessibilityCustomAction] = { [] }
    /// Elements under this one, for a group; nil for a leaf.
    var children: (() -> [Any])?
    /// Another element this one sits in, when it is not a direct child of the view.
    weak var container: NSAccessibilityElement?

    init(in view: NSView, role: NSAccessibility.Role, roleDescription: String? = nil,
         rect: @escaping () -> CGRect?, label: @escaping () -> String) {
        self.view = view
        self.rect = rect
        self.label = label
        super.init()

        setAccessibilityRole(role)

        if let roleDescription {
            setAccessibilityRoleDescription(roleDescription)
        }
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityParent() -> Any? { container ?? view }

    override func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window, let rect = rect() else { return .zero }

        return window.convertToScreen(view.convert(rect, to: nil))
    }

    override func accessibilityLabel() -> String? { label() }

    override func accessibilityValue() -> Any? { value?() }

    override func isAccessibilitySelected() -> Bool { isSelected() }

    override func accessibilityPerformPress() -> Bool { press?() ?? false }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let list = actions()

        return list.isEmpty ? nil : list
    }

    override func accessibilityChildren() -> [Any]? { children?() }

    /// The middle of the frame in the owning view's window, where a press that stands in for a
    /// click lands.
    var windowCentre: CGPoint? {
        guard let view, let rect = rect() else { return nil }

        return view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
    }
}
