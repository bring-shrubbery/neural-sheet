import NeuralSheetCore
import SwiftUI

/// The transport's position and total duration, `mm:ss.dd / mm:ss.dd` (`TimeDisplay.cpp`).
///
/// The playhead moves every frame, but the hundredths only change every other one and a stopped
/// transport never changes them at all, so the drawing is split off into `TimeDisplayBody`, an
/// `Equatable` leaf that SwiftUI re-renders only when the strings or the colour rule change. This
/// view's own body is re-evaluated with the playhead and does nothing but format.
struct TimeDisplay: View {
    let model: AppModel

    var body: some View {
        let readout = model.timeReadout

        TimeDisplayBody(position: readout.position,
                        total: readout.total,
                        isLive: model.state.canPlay)
            .equatable()
    }
}

/// What actually draws. Bracketed by two 1 px `divStrong` rules so they cannot drift from the text
/// they separate from the transport and from the empty stretch after it.
private struct TimeDisplayBody: View, Equatable {
    let position: String
    let total: String
    /// A zero that cannot move is not a reading: the position is `textBright` only once there is
    /// audio to play, and `textScale` before.
    let isLive: Bool

    @Environment(\.uiScale) private var k

    /// Authored extents, from `TimeDisplay.cpp` and `nn::metrics::controlHeight`.
    private static let sidePadding: CGFloat = 14
    private static let gap: CGFloat = 8
    private static let height: CGFloat = 30

    nonisolated static func == (lhs: TimeDisplayBody, rhs: TimeDisplayBody) -> Bool {
        lhs.position == rhs.position && lhs.total == rhs.total && lhs.isLive == rhs.isLive
    }

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: s(Self.gap)) {
            Text(position)
                .font(Fonts.transportTime(k))
                .foregroundStyle(isLive ? Theme.textBright : Theme.textScale)
                .fixedSize()

            Text("/ " + total)
                .font(Fonts.transportTotal(k))
                .foregroundStyle(Theme.textFaint)
                .fixedSize()
        }
        .padding(.horizontal, s(Self.sidePadding))
        .frame(height: s(Self.height))
        .overlay(alignment: .leading) { rule }
        .overlay(alignment: .trailing) { rule }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position \(position) of \(total)")
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.divStrong)
            .frame(width: Scaled(k: k)(1))
    }
}

#Preview("Time display") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()

    return VStack(spacing: 12) {
        TimeDisplay(model: model)
        TimeDisplay(model: model)
            .uiScale(1.5)
    }
    .padding(24)
    .background(Theme.bgTopBar)
}
