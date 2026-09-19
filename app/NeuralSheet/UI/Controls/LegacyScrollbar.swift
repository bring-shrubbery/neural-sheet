import SwiftUI

/// JUCE's vertical scrollbar as the viewports drew it (`LookAndFeel_V4::drawScrollbar`, no
/// buttons): an 8 px strip down the right of the viewport, visible whenever the content is taller
/// than it, taking its width off the content; a thumb rounded 4 and inset 1 in the bar's own
/// colour, a quarter brighter under the pointer, over a transparent track.
///
/// A `ScrollView` wears it through ``View/legacyScrollbar(thumb:)``, which measures the scroll
/// geometry, narrows the content by the bar while it shows, and draws the thumb over the trailing
/// edge. The wheel scrolls; the thumb is drawn, not dragged.
struct LegacyScrollbar: View {
    /// The content's height, the viewport's, and how far the content is scrolled, in points.
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
    let offset: CGFloat
    let thumb: Color

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    /// `LookAndFeel_V4::getDefaultScrollbarWidth`.
    static let width: CGFloat = 8

    /// `getMinimumScrollbarThumbSize`: twice the bar's width, or half its length on a short bar.
    static let minimumThumb: CGFloat = 16

    static func shows(contentHeight: CGFloat, visibleHeight: CGFloat) -> Bool {
        contentHeight > visibleHeight + 0.5 && visibleHeight > 0
    }

    var body: some View {
        let s = Scaled(k: k)
        let length = visibleHeight
        let thumbSize = max(min(length / 2, s(Self.minimumThumb)), (visibleHeight / contentHeight * length).rounded())
        let travel = max(0, contentHeight - visibleHeight)
        let start = travel > 0 ? ((length - thumbSize) * min(max(offset, 0), travel) / travel).rounded() : 0
        let colour = isHovered ? thumb.brighter(0.25) : thumb

        ZStack(alignment: .top) {
            Color.clear

            RoundedRectangle(cornerRadius: s(4), style: .circular)
                .fill(colour)
                .frame(width: s(Self.width) - 2 * k, height: max(0, thumbSize - 2 * k))
                .padding(.top, start + k)
        }
        .frame(width: s(Self.width), height: length, alignment: .top)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityHidden(true)
    }
}

/// The geometry a scrolled list reports, for the bar and for the content's trailing inset.
private struct ScrollExtent: Equatable {
    var contentHeight: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var offset: CGFloat = 0
}

/// Puts JUCE's scrollbar on a vertical `ScrollView`: the content is narrowed by the bar while it
/// shows, and the thumb is drawn over the viewport's trailing edge.
struct LegacyScrollbarModifier: ViewModifier {
    let thumb: Color

    @Environment(\.uiScale) private var k
    @State private var extent = ScrollExtent()

    private var shows: Bool {
        LegacyScrollbar.shows(contentHeight: extent.contentHeight, visibleHeight: extent.visibleHeight)
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .environment(\.legacyScrollbarInset, shows ? LegacyScrollbar.width * k : 0)
            .onScrollGeometryChange(for: ScrollExtent.self) { geometry in
                ScrollExtent(contentHeight: geometry.contentSize.height,
                             visibleHeight: geometry.containerSize.height,
                             offset: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, new in
                if new != extent {
                    extent = new
                }
            }
            .overlay(alignment: .topTrailing) {
                if shows {
                    LegacyScrollbar(contentHeight: extent.contentHeight,
                                    visibleHeight: extent.visibleHeight,
                                    offset: extent.offset,
                                    thumb: thumb)
                }
            }
    }
}

/// How much the scrolled content leaves for the bar: `Viewport::updateVisibleArea` took the
/// scrollbar's width off the content area. The content reads it and pads its trailing edge.
nonisolated struct LegacyScrollbarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    nonisolated var legacyScrollbarInset: CGFloat {
        get { self[LegacyScrollbarInsetKey.self] }
        set { self[LegacyScrollbarInsetKey.self] = newValue }
    }
}

extension View {
    /// See `LegacyScrollbar`. Apply to the `ScrollView`; its content pads its trailing edge by
    /// `\.legacyScrollbarInset`.
    func legacyScrollbar(thumb: Color) -> some View {
        modifier(LegacyScrollbarModifier(thumb: thumb))
    }
}
