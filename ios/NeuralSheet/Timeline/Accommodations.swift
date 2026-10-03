import Observation
import UIKit

/// The display accommodations the shared timeline drawing reads (`TimelinePalette`, the roll's
/// hatching, the keyboard's scale dots), as iOS reports them: the iPhone and iPad counterpart of
/// the Mac's `Accommodations`, with the same names, so the shared files compile unchanged
/// (iOS app design §2). Read at launch and again whenever UIKit says one changed.
@Observable final class Accommodations {
    static let shared = Accommodations()

    /// Increase Contrast (Settings → Accessibility → Display & Text Size).
    private(set) var increaseContrast = false
    /// Reduce Transparency.
    private(set) var reduceTransparency = false
    /// Reduce Motion: the playhead's follow turns a page rather than scrolling every frame.
    private(set) var reduceMotion = false
    /// Differentiate Without Colour: muted notes hatched and the key's scale dotted on the keys.
    private(set) var differentiateWithoutColour = false

    /// Posted on the default centre after a change, for the timeline's views to repaint.
    static let didChange = Notification.Name("NeuralSheet.AccommodationsDidChange")

    /// UIKit's observers. Never removed: the accommodations live as long as the app.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        read()

        let names: [Notification.Name] = [
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.differentiateWithoutColorDidChangeNotification,
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Accommodations.shared.read()
                    NotificationCenter.default.post(name: Accommodations.didChange, object: nil)
                }
            }
        }
    }

    /// Assigned only on a change, so an unrelated notification invalidates nothing.
    private func read() {
        if increaseContrast != UIAccessibility.isDarkerSystemColorsEnabled {
            increaseContrast = UIAccessibility.isDarkerSystemColorsEnabled
        }

        if reduceTransparency != UIAccessibility.isReduceTransparencyEnabled {
            reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        }

        if reduceMotion != UIAccessibility.isReduceMotionEnabled {
            reduceMotion = UIAccessibility.isReduceMotionEnabled
        }

        if differentiateWithoutColour != UIAccessibility.shouldDifferentiateWithoutColor {
            differentiateWithoutColour = UIAccessibility.shouldDifferentiateWithoutColor
        }
    }
}
