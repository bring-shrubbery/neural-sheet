import AppKit
import Observation

/// The four display accommodations in System Settings → Accessibility → Display, as the app
/// honours them (a11y design §2): read at launch and again whenever macOS says they changed.
///
/// Observable, so a SwiftUI body that drew with a `Theme` colour depending on one is drawn again
/// when it flips; the AppKit views listen for ``didChange`` and repaint. All four off -- the
/// default -- is the app exactly as it has always looked.
@Observable final class Accommodations {
    static let shared = Accommodations()

    /// Stronger borders and text at full contrast (`Theme+Accommodations`).
    private(set) var increaseContrast = false
    /// Opaque floating panels, without the drop shadow's veil.
    private(set) var reduceTransparency = false
    /// The playhead's follow jumps a page at a time instead of scrolling every frame.
    private(set) var reduceMotion = false
    /// Muted notes hatched and the key's scale marked on the keyboard, not by colour alone.
    private(set) var differentiateWithoutColour = false

    /// Posted on the default centre after a change, for the AppKit views.
    static let didChange = Notification.Name("NeuralSheet.AccommodationsDidChange")

    /// The workspace's observer. Never removed: the accommodations live as long as the app.
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        read()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Accommodations.shared.read()
                NotificationCenter.default.post(name: Accommodations.didChange, object: nil)
            }
        }
    }

    /// Assigned only on a change, so an unrelated notification invalidates nothing.
    private func read() {
        let workspace = NSWorkspace.shared

        if increaseContrast != workspace.accessibilityDisplayShouldIncreaseContrast {
            increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        }

        if reduceTransparency != workspace.accessibilityDisplayShouldReduceTransparency {
            reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        }

        if reduceMotion != workspace.accessibilityDisplayShouldReduceMotion {
            reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        }

        if differentiateWithoutColour != workspace.accessibilityDisplayShouldDifferentiateWithoutColor {
            differentiateWithoutColour = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        }
    }
}
