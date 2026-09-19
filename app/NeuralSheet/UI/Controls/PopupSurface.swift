import SwiftUI

/// The surface every floating panel sits on: menus, tooltips, the update notification
/// (`nn::drawPopupSurface`). A `popupBg` fill under a 1 px `popupBorder` outline.
///
/// The drop shadow falls outside the bounds, so it is optional: only the caller knows whether what
/// it is drawing into has the room for it. A tooltip, for instance, lives in its own window and
/// takes the window's shadow instead.
struct PopupSurface: ViewModifier {
    /// Already scaled by the caller, so a panel can round its corners to match its own metrics.
    /// `nil` takes the shared menu corner at the environment's scale -- a bare `8` as the default
    /// would silently be the wrong radius at every scale but 1.
    var corner: CGFloat?
    var shadow: Bool = true

    @Environment(\.uiScale) private var k

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner ?? MenuMetrics.corner * k, style: .circular)

        return content
            .background(shape.fill(Theme.popupBg))
            // strokeBorder, not stroke: JUCE insets the outline by half a pixel so the 1 px line
            // lands inside the fill rather than straddling its edge.
            .overlay(shape.strokeBorder(Theme.popupBorder, lineWidth: k))
            .compositingGroup()
            .shadow(color: shadow ? Theme.popupShadow : .clear,
                    radius: shadow ? 34 * k : 0,
                    x: 0,
                    y: shadow ? 14 * k : 0)
    }
}

extension View {
    /// Puts this content on the shared popup surface. See `PopupSurface`.
    func popupSurface(corner: CGFloat? = nil, shadow: Bool = true) -> some View {
        modifier(PopupSurface(corner: corner, shadow: shadow))
    }
}
