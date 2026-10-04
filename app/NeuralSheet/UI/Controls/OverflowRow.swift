import SwiftUI

/// A toolbar row that is exactly as wide as its container, whatever its controls add up to.
///
/// The toolbars are rows of fixed-size controls, and they have grown (TIME, SWING, the MIDI chip,
/// the key controls). When such a row is asked for less width than its controls need, SwiftUI
/// centres the overflowing row, so the sidebar slides out of the window on the left and the
/// row's trailing end on the right. Inside a horizontal scroll view the row's width is its own
/// business: the container stays the window's width, and a window narrower than the controls
/// scrolls the row sideways (with the trackpad; no scroller is shown, as the inventory's chrome
/// has none). The content is given the container's width as a minimum so a `Spacer` in the row
/// still pushes its trailing controls to the edge when there is room.
struct OverflowRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .frame(minWidth: geometry.size.width, alignment: .leading)
            }
        }
    }
}
