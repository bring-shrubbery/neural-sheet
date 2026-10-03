import NeuralSheetCore
import SwiftUI

/// "SPEED" ... slider ... "100%": how fast the take plays, its pitch unchanged (speed design §6),
/// in the metrics the volume pill had in this bar. The slider's centre is the take's own speed;
/// a double-click goes back to it. Dimmed until there is something to play.
struct SpeedPill: View {
    @Bindable private var model: AppModel

    @Environment(\.uiScale) private var k

    init(model: AppModel) {
        _model = Bindable(wrappedValue: model)
    }

    private static let height: CGFloat = 30
    private static let corner: CGFloat = 6
    private static let padding: CGFloat = 12
    private static let gap: CGFloat = 9
    /// The top bar's volume track.
    private static let trackWidth: CGFloat = 74
    /// Wide enough for "150%".
    private static let valueWidth: CGFloat = 34

    var body: some View {
        let s = Scaled(k: k)
        let alpha = model.state.canPlay ? 1.0 : Theme.disabledAlpha
        let percent = Int((model.playbackSpeed * 100).rounded())

        HStack(spacing: s(Self.gap)) {
            PillCaption(text: "SPEED", colour: Theme.textMuted)

            PillSlider(value: $model.playbackSpeed,
                       range: AppModel.speedRange,
                       step: AppModel.speedStep,
                       width: s(Self.trackWidth),
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb,
                       onDoubleClick: model.resetSpeed,
                       valueText: String(localized: AccessibilityText.percent(percent)))
                .tooltip("Playback speed, pitch unchanged | - =")
                .accessibilityLabel(Text(AccessibilityText.playbackSpeed))

            Text("\(percent)%")
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
                .frame(width: s(Self.valueWidth), alignment: .trailing)
        }
        .padding(.horizontal, s(Self.padding))
        .frame(height: s(Self.height))
        .background(RoundedRectangle(cornerRadius: s(Self.corner), style: .circular).fill(Theme.bgControl))
        .opacity(alpha)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AccessibilityText.playbackSpeed))
    }
}

/// A pill's caption, boxed at the tracked width `nn::trackedTextWidth` gave it (the mix pill's
/// labels are drawn the same way).
struct PillCaption: View {
    let text: String
    let colour: Color

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let width = TrackedText.width(text,
                                      fontName: Fonts.sansName(500),
                                      pointSize: Fonts.Size.pillLabel,
                                      trackingEm: Fonts.Tracking.pillLabel).rounded(.up)

        return Text(text)
            .font(Fonts.pillLabel(k))
            .kerning(Fonts.tracking(Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel, scale: k))
            .foregroundStyle(colour)
            .fixedSize()
            .frame(width: s(width), alignment: .leading)
    }
}

#Preview("Speed pill") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    model.playbackSpeed = 0.75

    return SpeedPill(model: model)
        .padding(24)
        .background(Theme.bgTopBar)
}
