import SwiftUI

/// The factor every authored extent is multiplied by. The UI was once drawn as a 1280 x 800
/// canvas scaled to the window, as the JUCE editor was; it now reflows at 1x, and nothing sets
/// this any more. The views still spell their extents `s(54)`, which is harmless at 1.
nonisolated struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The factor every authored extent is multiplied by; 1, the authored size, everywhere now.
    nonisolated var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// Scales authored extents, so a view reads `s(54)` where the mockup says 54 px.
///
/// A callable struct rather than a free function: views hold it once per body, and the multiplier
/// cannot drift from the one in the environment.
///
/// ```swift
/// @Environment(\.uiScale) private var k
/// ...
/// let s = Scaled(k: k)
/// Rectangle().frame(height: s(54))
/// ```
nonisolated struct Scaled {
    let k: CGFloat

    init(k: CGFloat) {
        self.k = k
    }

    func callAsFunction(_ v: CGFloat) -> CGFloat {
        v * k
    }
}

extension View {
    /// Sets the factor every extent below this view is multiplied by.
    func uiScale(_ scale: CGFloat) -> some View {
        environment(\.uiScale, scale)
    }
}
