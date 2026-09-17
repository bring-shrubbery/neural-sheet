import AppKit
import SwiftUI

/// Everything the tooltips share, including the switch the settings menu flips.
enum Tooltips {
    /// Off hides every tooltip immediately and stops new ones being scheduled. The settings menu
    /// toggles this; it starts on, as `TooltipWindow` did.
    static var enabled: Bool = true

    /// How long the pointer has to rest before a tip appears (`TooltipWindow(this, 800)`).
    static let delay: Duration = .milliseconds(800)

    /// Where a tooltip wraps. Two of the originals are already two lines, and one long line reads
    /// worse. Authored points: multiply by the UI scale.
    static let maxWidth: CGFloat = 260

    static let padY: CGFloat = 6

    /// The gaps JUCE's own placement leaves between the pointer and the tip.
    static let gapNear: CGFloat = 6
    static let gapLeading: CGFloat = 24
    static let gapTrailing: CGFloat = 12
}

/// A tooltip on the shared popup surface, shown after `Tooltips.delay` of hovering.
///
/// It lives in its own non-activating `NSPanel`, added as a child of the app's window rather than
/// drawn in the view tree: a tip on a control near the edge of a clipped container -- the sidebar's
/// strips, the toolbar -- would otherwise be cut off by the clip its owner needs.
struct TooltipModifier: ViewModifier {
    let text: String

    @Environment(\.uiScale) private var k

    @State private var hostWindow: NSWindow?
    @State private var panel: NSPanel?
    @State private var pending: Task<Void, Never>?
    @State private var dismissMonitor: Any?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window in
                if hostWindow !== window {
                    hostWindow = window
                }
            })
            .onHover { hovering in
                if hovering {
                    schedule()
                } else {
                    dismiss()
                }
            }
            .onChange(of: text) { _, _ in dismiss() }
            .onDisappear { dismiss() }
    }

    // MARK: - Scheduling

    private func schedule() {
        pending?.cancel()

        guard Tooltips.enabled, !text.isEmpty else {
            pending = nil
            return
        }

        let scale = k

        pending = Task {
            try? await Task.sleep(for: Tooltips.delay)

            guard !Task.isCancelled, Tooltips.enabled else { return }

            show(scale: scale)
        }
    }

    private func dismiss() {
        pending?.cancel()
        pending = nil

        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }

        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    // MARK: - The panel

    private func show(scale: CGFloat) {
        guard panel == nil, let hostWindow else { return }

        let body = TooltipBody(text: text, scale: scale)
        let hosting = NSHostingView(rootView: body)
        let size = body.panelSize

        hosting.frame = CGRect(origin: .zero, size: size)

        let tip = TooltipPanel(contentRect: CGRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        tip.contentView = hosting
        tip.isOpaque = false
        tip.backgroundColor = .clear
        // The window's own shadow rather than one drawn inside it: a shadow in the view tree would
        // be clipped by the panel it is drawn in.
        tip.hasShadow = true
        tip.level = .popUpMenu
        tip.ignoresMouseEvents = true
        tip.hidesOnDeactivate = true
        tip.animationBehavior = .none
        tip.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        tip.setFrame(Self.frame(for: size), display: false)

        hostWindow.addChildWindow(tip, ordered: .above)

        panel = tip

        // A tip that outlived the click that dismissed the thing under it would hang over the UI,
        // and the panel itself never sees events.
        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,
                                                                    .rightMouseDown,
                                                                    .otherMouseDown,
                                                                    .scrollWheel]) { event in
            dismiss()
            return event
        }
    }

    /// JUCE's placement, kept: the tip goes away from whichever screen edge the pointer is nearest,
    /// so it never lands on top of the thing being hovered. AppKit's y grows upward where JUCE's
    /// grew downward, so the two vertical branches swap.
    private static func frame(for size: CGSize) -> CGRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(origin: pointer, size: size)

        let x = pointer.x > area.midX
            ? pointer.x - (size.width + Tooltips.gapTrailing)
            : pointer.x + Tooltips.gapLeading

        let y = pointer.y < area.midY
            ? pointer.y + Tooltips.gapNear
            : pointer.y - (size.height + Tooltips.gapNear)

        var frame = CGRect(x: x, y: y, width: size.width, height: size.height)

        frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))

        return frame
    }
}

extension View {
    /// Shows `text` on the popup surface after the pointer has rested here for `Tooltips.delay`.
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

/// Non-activating so hovering a control never takes focus off whatever the user was typing in.
private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

/// The tip itself, sized here rather than by SwiftUI: the panel needs a frame before its content
/// view exists, so the text is measured with the same font it is then drawn in.
private struct TooltipBody: View {
    let text: String
    let scale: CGFloat

    private var maxTextWidth: CGFloat { Tooltips.maxWidth * scale - 2 * MenuMetrics.padX * scale }

    private var textSize: CGSize {
        let font = Fonts.nsFont(Fonts.Name.interRegular, pointSize: Fonts.Size.menuItem, scale: scale)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(with: CGSize(width: maxTextWidth,
                                                          height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])

        // Rounded up: half a point short of the laid-out width is a wrap that was not asked for.
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// What the panel is made, including the padding around the text.
    var panelSize: CGSize {
        let size = textSize

        return CGSize(width: size.width + 2 * MenuMetrics.padX * scale,
                      height: size.height + 2 * Tooltips.padY * scale)
    }

    var body: some View {
        let size = textSize

        Text(text)
            .font(Fonts.menuItem(scale))
            .foregroundStyle(Theme.popupItem)
            .multilineTextAlignment(.leading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(.horizontal, MenuMetrics.padX * scale)
            .padding(.vertical, Tooltips.padY * scale)
            .environment(\.uiScale, scale)
            .popupSurface(corner: MenuMetrics.corner * scale, shadow: false)
    }
}

/// Hands back the `NSWindow` the SwiftUI view ended up in, which is the parent the tooltip panel
/// attaches to.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
