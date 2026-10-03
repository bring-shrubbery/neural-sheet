import AppKit
import NeuralSheetCore
import SwiftUI

/// The grid and the key, shared by the Edit and Score toolbars (arrangement design §6): the
/// TEMPO field and the TIME menus for the segment under the playhead (tempo map design §4), BEAT
/// 1 AT with ⌖, Tap and Detect (tempo design §5), then the KEY tonic and mode (key design §5)
/// with their menus. Two groups at the toolbar's group gap, so they sit in
/// either row exactly as they did in the Edit toolbar alone.
struct GridControls: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var tonicMenu = PopupMenuPresenter()
    @State private var tonicAnchor: NSView?
    @State private var modeMenu = PopupMenuPresenter()
    @State private var modeAnchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let editor = model.editor

        HStack(spacing: s(Metrics.groupGap)) {
            HStack(spacing: s(6)) {
                SegmentControls(model: model)

                ToolbarControls.pillLabel(k: k, "BEAT 1 AT")
                NumberField(value: editor.grid.offsetSeconds, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 62) {
                    model.setGridOffset($0)
                }
                .tooltip("Where bar 1 starts, in seconds")
                .accessibilityLabel(Text(AccessibilityText.beatOneAt))

                ToolbarControls.iconButton(k: k, isOn: false, tooltip: "Set from playhead",
                                           label: Text(AccessibilityText.setBeatOneFromPlayhead),
                                           action: model.setGridOffsetFromPlayhead) {
                    Icons.PlayheadTargetStroked()
                }

                ToolbarControls.labelButton(k: k, "Tap", tooltip: "Tap in time with playback to set the tempo | t", action: model.tap)

                ToolbarControls.labelButton(k: k, "Detect", tooltip: "Find the tempo and its changes, the downbeat, the meter and the key",
                                            isEnabled: !model.isDetectingTempo, action: model.detectTempo)
            }

            // The key (key design §5): a tonic, then a mode once there is one.
            HStack(spacing: s(6)) {
                ToolbarControls.pillLabel(k: k, "KEY")

                ToolbarControls.labelButton(k: k, editor.key?.tonicName ?? "—", tooltip: "The project's key, or none",
                                            label: Text(AccessibilityText.keyTonic)) {
                    showTonicMenu()
                }
                .background(AnchorCatcher { tonicAnchor = $0 })

                ToolbarControls.labelButton(k: k, editor.key?.mode.name.capitalized ?? "Major", tooltip: "Major or minor",
                                            label: Text(AccessibilityText.keyMode), isEnabled: editor.key != nil) {
                    showModeMenu()
                }
                .background(AnchorCatcher { modeAnchor = $0 })
            }
        }
        // Switching tabs takes the row away; a menu left up would outlive the button it hangs
        // from, with its monitors and observers.
        .onDisappear {
            tonicMenu.dismiss()
            modeMenu.dismiss()
        }
    }

    // MARK: - Menus

    /// The tonic menu under its button: None, then the twelve pitch classes, the current one
    /// ticked.
    private func showTonicMenu() {
        guard let anchor = tonicAnchor else { return }

        let menu = tonicMenu
        let model = model
        let titles = ["None"] + (0..<12).map(MusicalKey.tonicMenuName)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            MenuRow(title: "None", isTicked: model.editor.key == nil) {
                menu.dismiss()
                model.setKeyTonic(nil)
            }

            MenuSeparator()

            ForEach(0..<12, id: \.self) { pitchClass in
                MenuRow(title: MusicalKey.tonicMenuName(pitchClass), isTicked: model.editor.key?.tonic == pitchClass) {
                    menu.dismiss()
                    model.setKeyTonic(pitchClass)
                }
            }
        }
    }

    /// The mode menu under its button.
    private func showModeMenu() {
        guard let anchor = modeAnchor else { return }

        let menu = modeMenu
        let model = model
        let width = PopupMenuPresenter.width(forTitles: ["Major", "Minor"], scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(MusicalKey.Mode.allCases, id: \.self) { mode in
                MenuRow(title: mode.name.capitalized, isTicked: model.editor.key?.mode == mode) {
                    menu.dismiss()
                    model.setKeyMode(mode)
                }
            }
        }
    }
}

/// TEMPO and TIME for the segment under the playhead: a view of its own, so following the
/// playhead redraws these and not the whole row.
private struct SegmentControls: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let segment = model.playheadSegment

        HStack(spacing: s(6)) {
            ToolbarControls.pillLabel(k: k, "TEMPO")
            NumberField(value: segment.bpm, range: TempoGrid.minBpm ... TempoGrid.maxBpm, decimals: 1, width: 50) {
                model.setGridBpm($0)
            }
            .tooltip("Tempo at the playhead, in quarter notes a minute")
            .accessibilityLabel(Text(AccessibilityText.tempo))

            ToolbarControls.pillLabel(k: k, "TIME")
            TimeSignatureMenus(meter: segment.timeSignature) { model.setTimeSignature($0) }
        }
    }
}

// MARK: - Controls

/// The toolbar rows' controls, at the scale the caller reads from the environment: an icon
/// button, a label button and the caps pill label in front of a field. One definition, so the
/// Edit and Score toolbars and the grid controls between them look alike.
enum ToolbarControls {
    private typealias Metrics = Toolbar.Metrics

    /// A square icon button, 4 short of the row's button height so three of them fit inside the
    /// tool tray's padding at the same height as the label buttons beside it.
    /// `label` names it for VoiceOver: the icon says nothing to it (a11y design §2).
    static func iconButton<Icon: Shape>(k: CGFloat, isOn: Bool, isEnabled: Bool = true, tooltip: String, label: Text,
                                        action: @escaping () -> Void, icon: () -> Icon) -> some View {
        let s = Scaled(k: k)
        let icon = icon()

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            icon.stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))
                .frame(width: s(Metrics.buttonHeight - 4), height: s(Metrics.buttonHeight - 4))
        }
        .tooltip(tooltip)
        .accessibilityLabel(label)
    }

    /// A button showing its value -- a division, a key, a numerator -- takes a `label` saying what
    /// the value is of, and VoiceOver reads the title as its value; a button whose title is an
    /// action is named by the title (a11y design §2).
    static func labelButton(k: CGFloat, _ title: String, tooltip: String, label: Text? = nil, isEnabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.textBright,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Metrics.buttonPadX))
                .frame(height: s(Metrics.buttonHeight))
        }
        .tooltip(tooltip)
        .accessibilityLabel(label ?? Text(verbatim: title))
        .accessibilityValue(label == nil ? Text(verbatim: "") : Text(verbatim: title))
    }

    /// The tracked caps label the sidebar's pills use, in front of each field.
    static func pillLabel(k: CGFloat, _ text: String) -> some View {
        TrackedLabel(string: text, em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                     font: Fonts.pillLabel(k), scale: k)
            .foregroundStyle(Theme.textLabel)
    }
}
