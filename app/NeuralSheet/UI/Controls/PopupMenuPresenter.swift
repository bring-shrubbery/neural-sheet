import AppKit
import SwiftUI

/// A `MenuPanel` shown the way `PopupMenu::showMenuAsync` placed it: in its own window, dismissed
/// by a click anywhere else (which is swallowed), by Escape or by the app deactivating. Also the
/// window for any other floating panel -- the roll's note card -- through ``showPanel``.
///
/// Its own window rather than an overlay in the view tree because a JUCE menu can hang past the
/// edge of the window it is opened from -- the settings menu under the gear does -- and because a
/// submenu is a second window beside the first.
///
/// Two placements, both `MenuWindow::calculateWindowPos`: a menu opened on a target component is
/// aligned to its rectangle (left edges flush, below it when there is room); a submenu is put
/// beside the row that opened it, to the right when it fits and the left otherwise. A panel at
/// a point hangs from the pointer, like a context menu.
@MainActor final class PopupMenuPresenter {
    enum Placement {
        /// `alignToRectangle`: the main menu under a control.
        case alignedToTarget
        /// A submenu beside its row.
        case besideTarget
    }

    private(set) var panel: NSPanel?
    private var hosting: KeyHostingView<AnyView>?
    private var shownWidth: CGFloat = 0
    private var shownScale: CGFloat = 1
    private var shownTitle: String?
    private var shownFooter: String?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// A submenu shown from one of this menu's rows: a click inside it is a click inside this
    /// menu, and this menu closing closes it.
    var child: PopupMenuPresenter?

    /// Called once the menu has gone, by whichever route.
    var onDismiss: (() -> Void)?

    /// `getIdealPopupMenuItemSize` plus the window's border: the widest title plus the paddings
    /// and the tick column, never narrower than the minimum, then the 4 px `PopupMenu` border on
    /// each side (`workOutManualSize`). Authored units in, scaled points out.
    static func width(forTitles titles: [String], scale: CGFloat) -> CGFloat {
        let font = NSFont(name: Fonts.Name.interRegular, size: Fonts.Size.menuItem)
            ?? NSFont.systemFont(ofSize: Fonts.Size.menuItem)
        let tickColumn = MenuMetrics.checkboxSize + MenuMetrics.padX
        let border = MenuMetrics.listPadY

        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0

        return (max(MenuMetrics.minWidth, ceil(widest) + 2 * MenuMetrics.padX + tickColumn) + 2 * border) * scale
    }

    /// Shows the menu aligned under `anchor`.
    func show<Rows: View>(from anchor: NSView,
                          width: CGFloat,
                          scale: CGFloat,
                          title: String? = nil,
                          footer: String? = nil,
                          @ViewBuilder rows: () -> Rows) {
        guard let window = anchor.window else { return }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        show(targetScreenRect: target, in: window, width: width, scale: scale, placement: .alignedToTarget,
             becomesKey: true, title: title, footer: footer, rows: rows)
    }

    /// Shows the menu placed against `target` (screen coordinates), as a child of `window`.
    ///
    /// - Parameter becomesKey: The main menu takes key so its rows get hover and clicks without
    ///   the app changing focus; a submenu must not, or the main menu would resign key and close.
    func show<Rows: View>(targetScreenRect target: CGRect,
                          in window: NSWindow,
                          width: CGFloat,
                          scale: CGFloat,
                          placement: Placement,
                          becomesKey: Bool,
                          title: String? = nil,
                          footer: String? = nil,
                          @ViewBuilder rows: () -> Rows) {
        let rows = rows()
        shownWidth = width
        shownScale = scale
        shownTitle = title
        shownFooter = footer

        present(AnyView(MenuPanel(title: title, footer: footer, width: width) { rows }.uiScale(scale)), in: window, scale: scale,
                becomesKey: becomesKey, swallowsOutsideClick: true) { size in
            switch placement {
            case .alignedToTarget: Self.alignedFrame(size: size, target: target, scale: scale)
            case .besideTarget: Self.besideFrame(size: size, target: target, scale: scale)
            }
        }
    }

    /// Shows `content` as a floating panel hanging from `point` (screen coordinates): a context
    /// card rather than a menu. It takes key, so a field in it can be typed in; the click that
    /// closes it goes on to whatever it landed on, so choosing another note is one click.
    func showPanel<Content: View>(at point: CGPoint,
                                  in window: NSWindow,
                                  scale: CGFloat,
                                  @ViewBuilder content: () -> Content) {
        let content = content()

        present(AnyView(content.uiScale(scale)), in: window, scale: scale, becomesKey: true, swallowsOutsideClick: false) { size in
            Self.pointFrame(size: size, point: point, scale: scale)
        }
    }

    /// The window, its monitors and its observers, whatever is shown in it.
    private func present(_ root: AnyView,
                         in window: NSWindow,
                         scale: CGFloat,
                         becomesKey: Bool,
                         swallowsOutsideClick: Bool,
                         frame frameFor: (CGSize) -> CGRect) {
        dismiss()

        let hosting = KeyHostingView(rootView: root)
        hosting.sizingOptions = []
        self.hosting = hosting

        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let menu = MenuWindow(contentRect: frameFor(size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        menu.takesKey = becomesKey
        menu.contentView = hosting
        menu.isOpaque = false
        menu.backgroundColor = .clear
        menu.hasShadow = true
        menu.level = .popUpMenu
        menu.hidesOnDeactivate = true
        menu.animationBehavior = .none
        menu.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        menu.isReleasedWhenClosed = false

        window.addChildWindow(menu, ordered: .above)

        if becomesKey {
            menu.makeKeyAndOrderFront(nil)
        } else {
            menu.orderFront(nil)
        }

        panel = menu

        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let panel = self.panel else { return event }

                if event.window === panel || (self.child?.panel != nil && event.window === self.child?.panel) {
                    return event
                }

                // Swallowed, as the modal menu swallowed it: the click closes the menu and does
                // nothing else. A panel lets it through.
                self.dismiss()

                return swallowsOutsideClick ? nil : event
            },
        ].compactMap { $0 }

        // Escape belongs to the menu that owns the keyboard; a submenu leaves it to its parent.
        if becomesKey {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard let self, self.panel != nil else { return event }

                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }

                return event
            }) {
                monitors.append(monitor)
            }

            observers.append(Self.observe(NSWindow.didResignKeyNotification, object: menu) { [weak self] in self?.dismiss() })
        }

        observers.append(Self.observe(NSApplication.didResignActiveNotification) { [weak self] in self?.dismiss() })
    }

    /// Re-renders the rows in place, for a row whose look depends on state kept outside the view
    /// tree (a submenu row highlighted while its submenu is open).
    func refresh<Rows: View>(@ViewBuilder rows: () -> Rows) {
        guard let hosting else { return }

        let rows = rows()
        hosting.rootView = AnyView(MenuPanel(title: shownTitle, footer: shownFooter, width: shownWidth) { rows }.uiScale(shownScale))
    }

    func dismiss() {
        child?.dismiss()
        child = nil

        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }

        monitors = []

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }

        observers = []

        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            hosting = nil
            onDismiss?()
        }
    }

    // MARK: - Placement (`calculateWindowPos`, in AppKit's bottom-up screen coordinates)

    private static func area(around target: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
            ?? NSScreen.main

        return screen?.visibleFrame ?? target
    }

    /// `alignToRectangle`: left-aligned with the target, below it unless the menu fits better
    /// above, then kept inside the screen's usable area.
    private static func alignedFrame(size: CGSize, target: CGRect, scale: CGFloat) -> CGRect {
        let area = area(around: target)

        let spaceUnder = target.minY - area.minY
        let spaceOver = area.maxY - target.maxY
        let buffer = 30 * scale

        let below = size.height < spaceUnder - buffer || spaceUnder >= spaceOver
        let origin = CGPoint(x: target.minX, y: below ? target.minY - size.height : target.maxY)

        return constrained(CGRect(origin: origin, size: size), in: area, scale: scale)
    }

    /// A submenu beside its row: to the right when that fits with 32 px to spare, else the side
    /// with more room; top-aligned with the row (less the 4 px list padding) in the upper half of
    /// the screen, bottom-aligned in the lower half.
    private static func besideFrame(size: CGSize, target: CGRect, scale: CGFloat) -> CGRect {
        let area = area(around: target)
        let border = MenuMetrics.listPadY * scale

        var tendTowardsRight = target.midX < area.midX

        if target.maxX + size.width < area.maxX - 32 * scale {
            tendTowardsRight = true
        }

        let biggestSpace = max(area.maxX - target.maxX, target.minX - area.minX) - 32 * scale

        if biggestSpace < size.width {
            tendTowardsRight = (area.maxX - target.maxX) >= (target.minX - area.minX)
        }

        let x = tendTowardsRight
            ? min(area.maxX - size.width - 4 * scale, target.maxX)
            : max(area.minX + 4 * scale, target.minX - size.width)

        // JUCE's y grows downward: its "target below the centre" is AppKit's `midY < area.midY`.
        let y = target.midY < area.midY
            ? min(area.maxY - size.height, target.minY) - border
            : target.maxY + border - size.height

        return constrained(CGRect(origin: CGPoint(x: x, y: y), size: size), in: area, scale: scale)
    }

    /// A panel hanging from the pointer: its top-left corner at `point`, inside the screen.
    private static func pointFrame(size: CGSize, point: CGPoint, scale: CGFloat) -> CGRect {
        let area = area(around: CGRect(origin: point, size: .zero))

        return constrained(CGRect(origin: CGPoint(x: point.x, y: point.y - size.height), size: size), in: area, scale: scale)
    }

    private static func constrained(_ frame: CGRect, in area: CGRect, scale: CGFloat) -> CGRect {
        var frame = frame

        frame.origin.x = max(area.minX + scale, min(area.maxX - (frame.width + 6 * scale), frame.minX))
        frame.origin.y = max(area.minY + 6 * scale, min(area.maxY - scale - frame.height, frame.minY))

        return frame
    }

    /// Takes key, when asked to, so the rows get their hover and click without the app changing
    /// focus first.
    private final class MenuWindow: NSPanel {
        var takesKey = true

        override var canBecomeKey: Bool { takesKey }

        override var canBecomeMain: Bool { false }
    }

    /// A hosting view that answers the first click in a window that was not key yet.
    private final class KeyHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// A block observer on the default centre, handed back so `dismiss` can remove it.
    private static func observe(_ name: Notification.Name,
                                object: Any? = nil,
                                _ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}
