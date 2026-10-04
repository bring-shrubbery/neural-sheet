import UIKit

/// Something a touch view draws rather than holds -- a note, the ruler, the keys, a staff system
/// -- as VoiceOver sees it: the Mac's `DrawnElement` over `UIAccessibilityElement` (a11y design
/// §2, sub-issue J). Every reading is asked of closures when VoiceOver asks, so an element made
/// once stays right while the view scrolls, zooms or repaints; the owning view only makes new ones
/// when *which* things it draws changes.
///
/// The frame is in the owning view's coordinates; the element converts it to the screen itself.
final class DrawnTouchElement: UIAccessibilityElement {
    private weak var view: UIView?
    private let rect: () -> CGRect?
    private let label: () -> String
    private let baseTraits: UIAccessibilityTraits

    /// Read for VoiceOver's value, after the label.
    var value: (() -> String?)?
    /// VoiceOver's double tap; nil makes the element read-only.
    var press: (() -> Bool)?
    var isSelected: () -> Bool = { false }
    /// The named actions VoiceOver lists in its actions rotor.
    var actions: () -> [UIAccessibilityCustomAction] = { [] }
    /// A swipe up or down on an adjustable element; setting either makes it adjustable.
    var increment: (() -> Void)?
    var decrement: (() -> Void)?
    /// VoiceOver landed on it: the owner scrolls it into view.
    var didBecomeFocused: (() -> Void)?

    /// `rect` is in `view`'s coordinates; `container` is the view that lists the element, `view`
    /// unless the frame is measured in a scroll view inside it.
    init(in view: UIView, container: UIView? = nil, traits: UIAccessibilityTraits, rect: @escaping () -> CGRect?,
         label: @escaping () -> String) {
        self.view = view
        self.rect = rect
        self.label = label
        baseTraits = traits
        super.init(accessibilityContainer: container ?? view)
        isAccessibilityElement = true
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let view, view.window != nil, let rect = rect() else { return .zero }

            return UIAccessibility.convertToScreenCoordinates(rect, in: view)
        }
        set {}
    }

    override var accessibilityLabel: String? {
        get { label() }
        set {}
    }

    override var accessibilityValue: String? {
        get { value?() }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = baseTraits

            if isSelected() { traits.insert(.selected) }
            if increment != nil || decrement != nil { traits.insert(.adjustable) }

            return traits
        }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let list = actions()
            return list.isEmpty ? nil : list
        }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        press?() ?? false
    }

    override func accessibilityIncrement() {
        increment?()
    }

    override func accessibilityDecrement() {
        decrement?()
    }

    override func accessibilityElementDidBecomeFocused() {
        didBecomeFocused?()
    }

    /// The frame in the owning view, where a press that stands in for a touch lands.
    var frameInView: CGRect? { rect() }
}

extension UIAccessibilityCustomAction {
    /// A named action that always succeeds.
    convenience init(_ name: String, perform: @escaping () -> Void) {
        self.init(name: name) { _ in
            perform()
            return true
        }
    }
}
