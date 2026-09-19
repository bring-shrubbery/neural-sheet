import CoreText
import NeuralSheetCore
import SwiftUI

/// The window's top strip (`TopBar.cpp`): wordmark, transport, position readout, model, mix, output
/// level, the input mute and the settings button. Authored 54 px tall, every extent scaled by
/// `\.uiScale`.
///
/// Left to right: wordmark (reserved 230), five transport buttons, `TimeDisplay`, the Model button,
/// a flexible gap, the mix pill, the volume pill, MUTE, settings. Every control is 30 tall and sits
/// at y = 11 in the 53 px above the 1 px bottom border, which is where JUCE's integer
/// `withSizeKeepingCentre` put them.
struct TopBar: View {
    @Bindable private var model: AppModel
    private let onSettings: () -> Void

    @Environment(\.uiScale) private var k

    /// - Parameter onSettings: Opens the settings menu (Task 20's `SettingsMenu`) from the gear.
    init(model: AppModel, onSettings: @escaping () -> Void) {
        _model = Bindable(wrappedValue: model)
        self.onSettings = onSettings
    }

    // MARK: - Authored metrics (`TopBar.cpp`, `NnLook.h`)

    private enum Metrics {
        static let height: CGFloat = 54
        static let paddingLeft: CGFloat = 18
        static let paddingRight: CGFloat = 14
        static let groupGap: CGFloat = 16
        static let transportGap: CGFloat = 2

        static let wordmarkWidth: CGFloat = 230
        static let wordmarkSquare: CGFloat = 9
        static let wordmarkSquareCorner: CGFloat = 2
        static let wordmarkVersionGap: CGFloat = 9
        static let wordmarkVersionDrop: CGFloat = 2

        static let transportButtonW: CGFloat = 34
        static let transportButtonH: CGFloat = 30
        static let controlHeight: CGFloat = 30
        static let controlCorner: CGFloat = 6

        /// `NnFlatButton::setPadding(11, 11, 7)` on the Model and MUTE buttons.
        static let labelPadX: CGFloat = 11
        static let iconLabelGap: CGFloat = 7

        static let pillPadding: CGFloat = 12
        static let pillGap: CGFloat = 9
        static let mixTrackWidth: CGFloat = 86
        static let volumeTrackWidth: CGFloat = 74
        /// Wide enough for -36.0, and what the instrument strips give the same readout.
        static let volumeValueWidth: CGFloat = 30
        static let speakerIconSize: CGFloat = 13
        static let muteIconSize: CGFloat = 14
        static let settingsWidth: CGFloat = 32
        static let settingsIconSize: CGFloat = 14
    }

    // MARK: - Body

    var body: some View {
        let s = Scaled(k: k)

        ZStack(alignment: .topLeading) {
            Theme.bgTopBar

            wordmark
                .padding(.leading, s(Metrics.paddingLeft))
                .frame(height: s(Metrics.height - 1))

            HStack(spacing: 0) {
                transport

                gap
                TimeDisplay(model: model)

                gap
                modelButton

                Spacer(minLength: 0)

                mixPill

                gap
                volumePill

                gap
                muteButton

                gap
                settingsButton
            }
            .frame(height: s(Metrics.controlHeight))
            .padding(.leading, s(Metrics.paddingLeft + Metrics.wordmarkWidth))
            .padding(.trailing, s(Metrics.paddingRight))
            // (53 - 30) / 2 in integers: the row sits at 11, not 11.5.
            .padding(.top, s(11))
        }
        .frame(maxWidth: .infinity)
        .frame(height: s(Metrics.height))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divStrong)
                .frame(height: s(1))
        }
    }

    private var gap: some View {
        Spacer(minLength: 0)
            .frame(width: Scaled(k: k)(Metrics.groupGap))
    }

    // MARK: - Wordmark

    /// A 9 x 9 accent square, the name in `wordmark` with 0.14 em tracking, then the version tag
    /// 9 px on and nudged 2 px down against the name's cap height.
    private var wordmark: some View {
        let s = Scaled(k: k)
        let nameTracking = Fonts.tracking(Fonts.Tracking.wordmark, pointSize: Fonts.Size.wordmark, scale: k)
        let versionTracking = Fonts.tracking(Fonts.Tracking.wordmarkVersion,
                                             pointSize: Fonts.Size.wordmarkVersion,
                                             scale: k)
        // The exact tracked width, as `paintWordmark` measured it: the version tag is placed
        // against it, not against a rounded-up box.
        let nameWidth = TrackedText.width("NEURALSHEET",
                                          fontName: Fonts.sansName(600),
                                          pointSize: Fonts.Size.wordmark,
                                          trackingEm: Fonts.Tracking.wordmark)

        return HStack(alignment: .center, spacing: 0) {
            RoundedRectangle(cornerRadius: s(Metrics.wordmarkSquareCorner), style: .circular)
                .fill(Theme.accent)
                .frame(width: s(Metrics.wordmarkSquare), height: s(Metrics.wordmarkSquare))
                // `paintWordmark` centred the square on the *integer* centre of the 53 px strip
                // (26, not 26.5), half a pixel above where the text is centred. A transform rather
                // than `offset`, which SwiftUI snaps to whole points.
                .transformEffect(CGAffineTransform(translationX: 0, y: -s(0.5)))

            Spacer(minLength: 0)
                .frame(width: s(Metrics.wordmarkSquare))

            Text("NEURALSHEET")
                .font(Fonts.wordmark(k))
                .kerning(nameTracking)
                .foregroundStyle(Theme.textBright)
                .fixedSize()
                .frame(width: s(nameWidth), alignment: .leading)

            Spacer(minLength: 0)
                .frame(width: s(Metrics.wordmarkVersionGap))

            Text("v1")
                .font(Fonts.wordmarkVersion(k))
                .kerning(versionTracking)
                .foregroundStyle(Theme.textFaint)
                .fixedSize()
                .offset(y: s(Metrics.wordmarkVersionDrop))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NeuralSheet v1")
    }

    // MARK: - Transport

    private var transport: some View {
        let s = Scaled(k: k)
        let canPlay = model.state.canPlay

        return HStack(spacing: s(Metrics.transportGap)) {
            transportButton(isEnabled: canPlay, action: model.goToStart) { _ in
                Icons.SkipToStart()
                    .fill(.foreground)
                    .frame(width: s(15), height: s(15))
            }
            .tooltip("Go to start | Shift + Space")

            // One button showing whichever icon is the action available now: pause while it plays.
            transportButton(isOn: model.isPlaying,
                            isEnabled: canPlay,
                            on: Theme.bgControlActive,
                            foregroundIdle: Theme.textPrimary,
                            foregroundOn: Theme.textPrimary,
                            action: model.togglePlay) { state in
                if state.isOn {
                    Icons.Pause()
                        .fill(.foreground)
                        .frame(width: s(16), height: s(16))
                } else {
                    Icons.Play()
                        .fill(.foreground)
                        .frame(width: s(15), height: s(15))
                }
            }
            .tooltip("Play / Pause | Space")

            // No loop transport yet; the button is here so the layout is the final one.
            transportButton(isEnabled: false,
                            on: Theme.accentFillActive,
                            foregroundOn: Theme.accent,
                            action: {}) { _ in
                ZStack {
                    Icons.LoopStroked()
                        .stroke(style: Icons.strokeStyle(scale: k))
                    Icons.LoopHead()
                        .fill(.foreground)
                }
                .frame(width: s(16), height: s(16))
            }
            .tooltip("Loop (not implemented yet)")

            transportButton(isOn: model.followPlayhead,
                            isEnabled: canPlay,
                            on: Theme.accentFillActive,
                            foregroundOn: Theme.accent,
                            action: { model.followPlayhead.toggle() }) { _ in
                ZStack {
                    Icons.FollowPlayheadStroked()
                        .stroke(style: Icons.strokeStyle(scale: k))
                    Icons.FollowPlayheadFlag()
                        .fill(.foreground)
                }
                .frame(width: s(16), height: s(16))
            }
            .tooltip("Center playhead | c")

            transportButton(isOn: model.state == .recording,
                            isEnabled: model.canRecord,
                            on: Theme.rec.opacity(0.14),
                            foregroundIdle: Theme.recIdle,
                            foregroundOn: Theme.rec,
                            action: model.toggleRecord) { _ in
                Icons.Record()
                    .fill(.foreground)
                    .frame(width: s(16), height: s(16))
            }
            .tooltip("Record | r")
        }
    }

    /// A 34 x 30 transparent button; hover lifts it onto the shared hover surface.
    private func transportButton<Icon: View>(isOn: Bool = false,
                                             isEnabled: Bool,
                                             on: Color = Theme.bgControlActive,
                                             foregroundIdle: Color = Theme.textIcon,
                                             foregroundOn: Color = Theme.textPrimary,
                                             action: @escaping () -> Void,
                                             @ViewBuilder icon: @escaping (ButtonVisualState) -> Icon) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: .clear,
                          on: on,
                          foregroundIdle: foregroundIdle,
                          foregroundOn: foregroundOn,
                          corner: s(Metrics.controlCorner),
                          action: action) { state in
            icon(state)
                .frame(width: s(Metrics.transportButtonW), height: s(Metrics.transportButtonH))
        }
    }

    // MARK: - Model

    private var modelButton: some View {
        let s = Scaled(k: k)
        // "Model: Small" upper-cased, as `syncModelButton` builds it.
        let label = ("Model: " + (model.modelSize?.displayName ?? "None")).uppercased()

        return FlatButton(isOn: model.isModelPanelOpen,
                          idle: Theme.bgControl,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.controlCorner),
                          action: { model.isModelPanelOpen.toggle() }) { _ in
            labelledContent(contentWidth: sectionLabelWidth(label)) {
                sectionLabel(label)
            }
        }
        .tooltip("Choose the transcription model, or download another")
    }

    /// The rounded-up tracked width `NnFlatButton::getIdealWidth` gave a `sectionHeader` label, in
    /// authored points.
    private func sectionLabelWidth(_ text: String) -> CGFloat {
        TrackedText.width(text,
                          fontName: Fonts.sansName(600),
                          pointSize: Fonts.Size.sectionHeader,
                          trackingEm: Fonts.Tracking.sectionHeaderPill).rounded(.up)
    }

    /// The Model and MUTE labels: `sectionHeader` with the pills' tighter 0.09 em tracking, boxed at
    /// the width `sectionLabelWidth` gives.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Fonts.sectionHeader(k))
            .kerning(Fonts.tracking(Fonts.Tracking.sectionHeaderPill,
                                    pointSize: Fonts.Size.sectionHeader,
                                    scale: k))
            .fixedSize()
            .frame(width: Scaled(k: k)(sectionLabelWidth(text)), alignment: .leading)
    }

    /// A labelled button's content row with `NnFlatButton`'s (11, 11, 7) padding, 30 tall.
    ///
    /// `paintButton` centred the row on the integer centre of its content box, so a row of odd
    /// width lands half a pixel left of the padding edge. `contentWidth` is the row's authored
    /// width in whole points (icon + gap + rounded-up label), which is what decides that.
    private func labelledContent<Content: View>(contentWidth: CGFloat,
                                                @ViewBuilder content: () -> Content) -> some View {
        let s = Scaled(k: k)
        let halfPixelLeft = contentWidth.truncatingRemainder(dividingBy: 2) != 0

        return content()
            // A transform rather than `offset`, which SwiftUI snaps to whole points.
            .transformEffect(CGAffineTransform(translationX: halfPixelLeft ? -s(0.5) : 0, y: 0))
            .padding(.horizontal, s(Metrics.labelPadX))
            .frame(height: s(Metrics.controlHeight))
    }

    // MARK: - Mix pill

    /// "ORIG" ... 86 px slider ... "MIDI". Dimmed rather than disabled while there are no notes to
    /// balance against: what it sets survives a take being cleared.
    private var mixPill: some View {
        let s = Scaled(k: k)
        let alpha = model.notes.isEmpty ? Theme.disabledAlpha : 1.0

        return HStack(spacing: s(Metrics.pillGap)) {
            pillLabel("ORIG", colour: Theme.textMuted)

            PillSlider(value: $model.mix,
                       range: 0 ... 1,
                       step: 0.001,
                       width: s(Metrics.mixTrackWidth),
                       fill: Theme.accent.opacity(0.8),
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb)
                .tooltip("Balance between the source audio and the synthesised transcription")

            pillLabel("MIDI", colour: Theme.accentText)
        }
        .padding(.horizontal, s(Metrics.pillPadding))
        .frame(height: s(Metrics.controlHeight))
        .background(pillSurface)
        .opacity(alpha)
    }

    private func pillLabel(_ text: String, colour: Color) -> some View {
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

    // MARK: - Volume pill

    /// Speaker, 74 px fader, 30 px right-aligned dB readout. Dimmed until there is something to hear.
    private var volumePill: some View {
        let s = Scaled(k: k)
        let alpha = model.state.canPlay ? 1.0 : Theme.disabledAlpha

        return HStack(spacing: s(Metrics.pillGap)) {
            Icons.Speaker()
                .fill(Theme.textIcon)
                .frame(width: s(Metrics.speakerIconSize), height: s(Metrics.speakerIconSize))

            PillSlider(value: $model.masterGainDb,
                       range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                       step: 0.1,
                       width: s(Metrics.volumeTrackWidth),
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb)
                .tooltip("Output level")

            Text(TimeFormat.decibels(model.masterGainDb))
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
                .frame(width: s(Metrics.volumeValueWidth), alignment: .trailing)
        }
        .padding(.horizontal, s(Metrics.pillPadding))
        .frame(height: s(Metrics.controlHeight))
        .background(pillSurface)
        .opacity(alpha)
    }

    private var pillSurface: some View {
        RoundedRectangle(cornerRadius: Scaled(k: k)(Metrics.controlCorner), style: .circular)
            .fill(Theme.bgControl)
    }

    // MARK: - Mute

    private var muteButton: some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: model.inputMuted,
                          idle: Theme.bgControl,
                          on: Theme.bgMuteActive,
                          foregroundIdle: Theme.textIcon,
                          foregroundOn: Theme.warn,
                          corner: s(Metrics.controlCorner),
                          action: { model.inputMuted.toggle() }) { _ in
            labelledContent(contentWidth: Metrics.muteIconSize + Metrics.iconLabelGap + sectionLabelWidth("MUTE")) {
                HStack(spacing: s(Metrics.iconLabelGap)) {
                    Icons.SpeakerMuted()
                        .fill(.foreground)
                        .frame(width: s(Metrics.muteIconSize), height: s(Metrics.muteIconSize))

                    sectionLabel("MUTE")
                }
            }
        }
        .tooltip("Mute / Unmute input | m")
    }

    // MARK: - Settings

    private var settingsButton: some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControl,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textIcon,
                          foregroundOn: Theme.textPrimary,
                          corner: s(Metrics.controlCorner),
                          action: onSettings) { _ in
            Icons.SettingsStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.settingsIconSize), height: s(Metrics.settingsIconSize))
                .frame(width: s(Metrics.settingsWidth), height: s(Metrics.controlHeight))
        }
        .tooltip("Settings")
    }
}

// MARK: - Tracked text measurement

/// The width `nn::trackedTextWidth` gave a label: the natural advance plus one tracking step per
/// gap between glyphs, measured at the authored size. The caller scales the result.
///
/// Measured rather than left to the stack, because SwiftUI's `kerning` also pads *after* the last
/// glyph, and because the original rounded each label up to a whole pixel before laying the bar out
/// around it. A `Text` drawn `fixedSize` inside a frame of this width lands its glyphs where JUCE
/// landed them.
enum TrackedText {
    static func width(_ text: String, fontName: String, pointSize: CGFloat, trackingEm: Double) -> CGFloat {
        let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let gaps = CGFloat(max(0, text.count - 1))

        return natural + gaps * CGFloat(trackingEm) * pointSize
    }
}

// MARK: - Previews

#Preview("Top bar, empty") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()

    return TopBar(model: model, onSettings: {})
        .frame(width: 1280)
        .background(Theme.bgRoot)
}

#Preview("Top bar, model panel open, muted, follow off") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    model.isModelPanelOpen = true
    model.inputMuted = true
    model.followPlayhead = false
    model.mix = 0.25
    model.masterGainDb = -6

    return TopBar(model: model, onSettings: {})
        .frame(width: 1280)
        .background(Theme.bgRoot)
}

#Preview("Top bar @ 1.5x") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()

    return TopBar(model: model, onSettings: {})
        .uiScale(1.5)
        .frame(width: 1920)
        .background(Theme.bgRoot)
}
