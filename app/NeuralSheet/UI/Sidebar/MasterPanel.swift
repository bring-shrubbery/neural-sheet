import CoreText
import NeuralSheetCore
import SwiftUI

/// The panel pinned to the bottom of the sidebar (§1.4): a "MASTER" label over the 26-segment
/// master meter, under a `divSoft` top border, and below the meter the output level and MUTE,
/// which the inventory had in the top bar and now sit beside the level they act on. 92 authored
/// points tall.
struct MasterPanel: View {
    @Bindable private var model: AppModel
    /// The panel's width in authored points: the sidebar's column, less its border.
    private let width: CGFloat

    @Environment(\.uiScale) private var k

    init(model: AppModel, width: CGFloat = SidebarMetrics.stripWidth) {
        _model = Bindable(wrappedValue: model)
        self.width = width
    }

    // MARK: - Authored extents (`Sidebar.cpp`, `TopBar.cpp`, `nn::metrics`)

    static let height: CGFloat = 92
    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let meterTopGap: CGFloat = 10
    private static let meterHeight: CGFloat = 5
    private static let meterSegments = 26
    private static let meterGap: CGFloat = 3
    private static let controlsTopGap: CGFloat = 10

    /// The top bar's pill and button metrics, so the controls look as they did there.
    private static let controlHeight: CGFloat = 30
    private static let controlCorner: CGFloat = 6
    private static let pillPadding: CGFloat = 12
    private static let pillGap: CGFloat = 9
    /// Narrower than the top bar's 74: the pill and MUTE share the column.
    private static let volumeTrackWidth: CGFloat = 60
    /// Wide enough for -36.0, and what the instrument strips give the same readout.
    private static let volumeValueWidth: CGFloat = 30
    private static let speakerIconSize: CGFloat = 13
    private static let muteIconSize: CGFloat = 14
    /// `NnFlatButton::setPadding(11, 11, 7)` on the MUTE button.
    private static let labelPadX: CGFloat = 11
    private static let iconLabelGap: CGFloat = 7

    var body: some View {
        let s = Scaled(k: k)

        VStack(alignment: .leading, spacing: 0) {
            Text("MASTER")
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                        pointSize: Fonts.Size.sectionHeader,
                                        scale: k))
                .foregroundStyle(Theme.textLabel)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)

            LevelMeter(db: model.masterLevelDb,
                       segments: Self.meterSegments,
                       gap: Self.meterGap,
                       height: Self.meterHeight,
                       unlit: Theme.meterUnlitMaster)
                .padding(.top, s(Self.meterTopGap))

            HStack(spacing: 0) {
                volumePill

                Spacer(minLength: s(8))

                muteButton
            }
            .frame(height: s(Self.controlHeight))
            .padding(.top, s(Self.controlsTopGap))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(width), height: s(Self.height), alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }

    // MARK: - Volume pill

    /// Speaker, fader, right-aligned dB readout. Dimmed until there is something to hear.
    private var volumePill: some View {
        let s = Scaled(k: k)
        let alpha = model.state.canPlay ? 1.0 : Theme.disabledAlpha

        return HStack(spacing: s(Self.pillGap)) {
            Icons.Speaker()
                .fill(Theme.textIcon)
                .frame(width: s(Self.speakerIconSize), height: s(Self.speakerIconSize))

            PillSlider(value: $model.masterGainDb,
                       range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                       step: 0.1,
                       width: s(Self.volumeTrackWidth),
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb)
                .tooltip("Output level")

            Text(TimeFormat.decibels(model.masterGainDb))
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
                .frame(width: s(Self.volumeValueWidth), alignment: .trailing)
        }
        .padding(.horizontal, s(Self.pillPadding))
        .frame(height: s(Self.controlHeight))
        .background(RoundedRectangle(cornerRadius: s(Self.controlCorner), style: .circular).fill(Theme.bgControl))
        .opacity(alpha)
    }

    // MARK: - Mute

    private var muteButton: some View {
        let s = Scaled(k: k)
        let labelWidth = Self.sectionLabelWidth("MUTE")
        // `paintButton` centred the row on the integer centre of its content box, so a row of
        // odd width lands half a pixel left of the padding edge.
        let contentWidth = Self.muteIconSize + Self.iconLabelGap + labelWidth
        let halfPixelLeft = contentWidth.truncatingRemainder(dividingBy: 2) != 0

        return FlatButton(isOn: model.inputMuted,
                          idle: Theme.bgControl,
                          on: Theme.bgMuteActive,
                          foregroundIdle: Theme.textIcon,
                          foregroundOn: Theme.warn,
                          corner: s(Self.controlCorner),
                          action: { model.inputMuted.toggle() }) { _ in
            HStack(spacing: s(Self.iconLabelGap)) {
                Icons.SpeakerMuted()
                    .fill(.foreground)
                    .frame(width: s(Self.muteIconSize), height: s(Self.muteIconSize))

                Text("MUTE")
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeaderPill,
                                            pointSize: Fonts.Size.sectionHeader,
                                            scale: k))
                    .fixedSize()
                    .frame(width: s(labelWidth), alignment: .leading)
            }
            // A transform rather than `offset`, which SwiftUI snaps to whole points.
            .transformEffect(CGAffineTransform(translationX: halfPixelLeft ? -s(0.5) : 0, y: 0))
            .padding(.horizontal, s(Self.labelPadX))
            .frame(height: s(Self.controlHeight))
        }
        .tooltip("Mute / Unmute input | m")
    }

    /// The rounded-up tracked width `NnFlatButton::getIdealWidth` gave a `sectionHeader` label
    /// at the pills' tighter tracking, in authored points.
    private static func sectionLabelWidth(_ text: String) -> CGFloat {
        TrackedText.width(text,
                          fontName: Fonts.sansName(600),
                          pointSize: Fonts.Size.sectionHeader,
                          trackingEm: Fonts.Tracking.sectionHeaderPill).rounded(.up)
    }
}

#Preview("Master panel") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    let muted = AppModel()
    muted.inputMuted = true
    muted.masterGainDb = -6

    return VStack(spacing: 0) {
        MasterPanel(model: model)
        MasterPanel(model: muted)
    }
    .background(Theme.bgSidebar)
}
