import AppKit
import NeuralSheetCore

/// Settings → General → Appearance, and the palette following it (native chrome design §2).
///
/// The setting becomes `NSApp.appearance` -- nil for System, so the Mac's own Light / Dark is
/// followed live -- and the effective appearance AppKit resolves from it becomes
/// ``ThemeAppearance/isDark``, which every `Theme` and `TimelinePalette` colour reads. A flip
/// repaints every window: the SwiftUI bodies redraw through the observable flag, the AppKit
/// views through `Accommodations.didChange` (the timeline also rebuilds what it configured) and a
/// pass marking every view for display.
@MainActor final class AppearanceTracker {
    static let shared = AppearanceTracker()

    /// The application's key-value observation. Never invalidated: the tracker lives as long as
    /// the app.
    private var observation: NSKeyValueObservation?

    private init() {}

    /// Once, at launch, before the first window: applies the setting and starts following the
    /// appearance it resolves to.
    func start(setting: AppearanceSetting) {
        apply(setting)
        update()

        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            MainActor.assumeIsolated {
                AppearanceTracker.shared.update()
            }
        }
    }

    /// The setting as the application's appearance: nil follows the system.
    func apply(_ setting: AppearanceSetting) {
        switch setting {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Reads the effective appearance; on a change, flips the palette and repaints.
    private func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        guard ThemeAppearance.shared.isDark != isDark else { return }

        ThemeAppearance.shared.isDark = isDark
        NotificationCenter.default.post(name: Accommodations.didChange, object: nil)

        for window in NSApp.windows {
            window.contentView?.repaintForPalette()
        }
    }
}

extension NSView {
    /// Marks this view and every view under it for display, so a view that paints with
    /// `TimelinePalette` in `draw` or `updateLayer` paints with the palette now in force.
    /// The playhead hosts a layer that draws itself, which a view's display does not reach.
    func repaintForPalette() {
        needsDisplay = true

        if let playhead = self as? PlayheadView {
            playhead.playheadLayer.setNeedsDisplay()
        }

        for subview in subviews {
            subview.repaintForPalette()
        }
    }
}
