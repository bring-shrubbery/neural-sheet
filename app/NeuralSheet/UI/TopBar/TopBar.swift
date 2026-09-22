import CoreText
import NeuralSheetCore
import SwiftUI

/// The window's top strip (`TopBar.cpp`): transport and position readout. Authored 54 px tall,
/// every extent scaled by `\.uiScale`.
///
/// Left to right: five transport buttons, `TimeDisplay`, then the rest of the row empty. Every
/// control is 30 tall and sits at y = 11 in the 53 px above the 1 px bottom border, which is
/// where JUCE's integer `withSizeKeepingCentre` put them. The wordmark, the Model button and the
/// gear NeuralNote had here are gone: the model and the settings live in the Settings window
/// (⌘,), and the wordmark only took room from the transport. The mix pill, the volume pill and
/// MUTE that ended the row have moved to the sidebar's master panel (`MasterPanel`), beside the
/// level they act on.
struct TopBar: View {
    @Bindable private var model: AppModel

    @Environment(\.uiScale) private var k

    init(model: AppModel) {
        _model = Bindable(wrappedValue: model)
    }

    // MARK: - Authored metrics (`TopBar.cpp`, `NnLook.h`)

    private enum Metrics {
        static let height: CGFloat = 54
        static let paddingLeft: CGFloat = 18
        static let paddingRight: CGFloat = 14
        static let groupGap: CGFloat = 16
        static let transportGap: CGFloat = 2

        static let transportButtonW: CGFloat = 34
        static let transportButtonH: CGFloat = 30
        static let controlHeight: CGFloat = 30
        static let controlCorner: CGFloat = 6
    }

    // MARK: - Body

    var body: some View {
        let s = Scaled(k: k)

        ZStack(alignment: .topLeading) {
            Theme.bgTopBar

            HStack(spacing: 0) {
                transport

                gap
                TimeDisplay(model: model)

                Spacer(minLength: 0)
            }
            .frame(height: s(Metrics.controlHeight))
            .padding(.leading, s(Metrics.paddingLeft))
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
            .tooltip("Go to start | Enter")

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

    return TopBar(model: model)
        .frame(width: 1280)
        .background(Theme.bgRoot)
}

#Preview("Top bar, follow off") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    model.followPlayhead = false
    model.mix = 0.25

    return TopBar(model: model)
        .frame(width: 1280)
        .background(Theme.bgRoot)
}

#Preview("Top bar @ 1.5x") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()

    return TopBar(model: model)
        .uiScale(1.5)
        .frame(width: 1920)
        .background(Theme.bgRoot)
}
