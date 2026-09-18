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

        let hosting = NSHostingView(rootView: TooltipBody(text: text, scale: scale))
        let size = Self.wrappedSize(of: hosting, scale: scale)

        // Left to itself, an NSHostingView acting as a window's content view keeps publishing
        // sizing constraints, and the layout pass that addChildWindow triggers re-measures the text
        // against a width it has not been given yet -- which grew the panel to a hundred lines. The
        // size measured above is the answer; the view is pinned to it and stops negotiating.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

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

    /// SwiftUI's own measurement of what it is about to draw.
    ///
    /// Two passes, because `fittingSize` on its own reports the *unwrapped* ideal -- one line,
    /// however long the tip. The first pass gives that ideal width, which is clamped to the cap;
    /// pinning the view to it makes the second pass report the height the text really wraps to.
    /// Measuring the text with AppKit instead and pinning SwiftUI to the result is what clipped the
    /// last line whenever the two line breakers disagreed about where a tip wraps.
    private static func wrappedSize(of hosting: NSView, scale: CGFloat) -> CGSize {
        // NnLook.cpp:134 lays the text out at 260 and adds the padding after, so the panel runs to
        // 282 and it is the text that wraps at 260.
        let cap = (Tooltips.maxWidth + 2 * MenuMetrics.padX) * scale

        hosting.translatesAutoresizingMaskIntoConstraints = false

        let width = min(hosting.fittingSize.width, cap)
        let pinned = hosting.widthAnchor.constraint(equalToConstant: width)

        pinned.isActive = true
        hosting.layoutSubtreeIfNeeded()

        let height = hosting.fittingSize.height

        pinned.isActive = false
        hosting.translatesAutoresizingMaskIntoConstraints = true

        return CGSize(width: width, height: height)
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

/// The tip itself. Nothing here pins the text to a measured box: the only layout that can be
/// trusted to agree with SwiftUI's line breaker is SwiftUI's own, and a frame measured with AppKit
/// clips the last line whenever the two disagree about where a two-line tip wraps. The text is
/// given a maximum width and nothing else; `TooltipModifier.wrappedSize` reports what it came to.
private struct TooltipBody: View {
    let text: String
    let scale: CGFloat

    /// `NnLook.cpp:134` lays the text out at 260 and then adds the padding, so the *text* is what
    /// wraps at 260 and the panel runs to 282.
    private var maxTextWidth: CGFloat { Tooltips.maxWidth * scale }

    var body: some View {
        Text(text)
            .font(Fonts.menuItem(scale))
            .foregroundStyle(Theme.popupItem)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxTextWidth, alignment: .topLeading)
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
