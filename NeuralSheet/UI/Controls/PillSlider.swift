import SwiftUI

/// The flat horizontal fader used by the dry/wet control, the output volume and every instrument
/// strip (`NnFlatSlider`): a 3 px track, a fill up to the value, and a 3 x 11 thumb.
///
/// The thumb travel is inset by `thumbIndent` at both ends and the drag maps across exactly that
/// same span, so the thumb always sits under the pointer.
struct PillSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 0 for a continuous fader.
    let step: Double
    /// The slider's own width, in points, already scaled by the caller.
    let width: CGFloat
    let fill: Color
    let track: Color
    /// `nil` draws no thumb, for the meters-style faders that are a bar and nothing else.
    let thumb: Color?
    /// What a double-click resets to, if anything. Every fader in the original resets this way.
    let onDoubleClick: (() -> Void)?

    @Environment(\.uiScale) private var k
    @Environment(\.isEnabled) private var isEnabled

    /// Authored extents, from `NnFlatSlider`.
    private static let trackHeight: CGFloat = 3
    private static let thumbWidth: CGFloat = 3
    private static let thumbHeight: CGFloat = 11
    /// Half the thumb, rounded up, so the travel can be expressed on both sides.
    private static let thumbIndent: CGFloat = 2

    init(value: Binding<Double>,
         range: ClosedRange<Double>,
         step: Double = 0,
         width: CGFloat,
         fill: Color,
         track: Color,
         thumb: Color? = nil,
         onDoubleClick: (() -> Void)? = nil) {
        self._value = value
        self.range = range
        self.step = step
        self.width = width
        self.fill = fill
        self.track = track
        self.thumb = thumb
        self.onDoubleClick = onDoubleClick
    }

    var body: some View {
        let s = Scaled(k: k)
        let height = s(Self.thumbHeight)
        let trackHeight = s(Self.trackHeight)
        let indent = s(Self.thumbIndent)
        let travel = max(1, width - 2 * indent)
        let centre = indent + CGFloat(proportion) * travel

        ZStack(alignment: .leading) {
            Capsule(style: .circular)
                .fill(track)
                .frame(width: width, height: trackHeight)

            Capsule(style: .circular)
                .fill(fill)
                .frame(width: max(0, centre), height: trackHeight)

            if let thumb {
                Capsule(style: .circular)
                    .fill(thumb)
                    .frame(width: s(Self.thumbWidth), height: height)
                    .offset(x: centre - s(Self.thumbWidth) / 2)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : Theme.disabledAlpha)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onDoubleClick?() },
                             including: (isEnabled && onDoubleClick != nil) ? .all : .subviews)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { setValue(atX: $0.location.x, travel: travel, indent: indent) }
            .onEnded { setValue(atX: $0.location.x, travel: travel, indent: indent) },
            including: isEnabled ? .all : .subviews)
        .pointerStyle(isEnabled ? .link : nil)
        .accessibilityValue(Text(String(format: "%.2f", value)))
    }

    private var proportion: Double {
        let span = range.upperBound - range.lowerBound

        guard span > 0 else { return 0 }

        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func setValue(atX x: CGFloat, travel: CGFloat, indent: CGFloat) {
        let span = range.upperBound - range.lowerBound

        guard span > 0 else { return }

        let proportion = min(1, max(0, Double((x - indent) / travel)))
        var next = range.lowerBound + proportion * span

        if step > 0 {
            next = range.lowerBound + (next - range.lowerBound).rounded(toNearestMultipleOf: step)
        }

        let clamped = min(range.upperBound, max(range.lowerBound, next))

        if clamped != value {
            value = clamped
        }
    }
}

private extension Double {
    func rounded(toNearestMultipleOf step: Double) -> Double {
        (self / step).rounded() * step
    }
}
