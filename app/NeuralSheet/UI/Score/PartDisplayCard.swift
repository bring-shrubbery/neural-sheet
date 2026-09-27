import AppKit
import NeuralSheetCore
import SwiftUI

/// A part's display (arrangement design §6): opened by a click on its name in the score. Rows
/// for the display mode, the clef, the transposition, the tab template and tuning, the frets
/// and a hide switch; every change goes straight to the model. The same floating panel as the
/// strip card, its menus opened as the panel's children so the panel stays up under them.
struct PartDisplayCard: View {
    let model: AppModel
    let program: Int
    /// The panel this card is in, so the menus open as its children.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k
    @State private var clefMenu = PopupMenuPresenter()
    @State private var clefAnchor: NSView?
    @State private var transpositionMenu = PopupMenuPresenter()
    @State private var transpositionAnchor: NSView?
    @State private var templateMenu = PopupMenuPresenter()
    @State private var templateAnchor: NSView?
    @State private var tuningMenu = PopupMenuPresenter()
    @State private var tuningAnchor: NSView?

    static let width: CGFloat = 260
    private static let padding: CGFloat = 12
    private static let rowGap: CGFloat = 8
    private static let labelWidth: CGFloat = 84

    /// Written = sounding + semitones.
    static let transpositionPresets: [(String, Int)] = [
        ("None", 0), ("B♭ (+2)", 2), ("B♭ tenor (+14)", 14), ("E♭ alto (+9)", 9), ("E♭ baritone (+21)", 21),
        ("F (+7)", 7), ("A (+3)", 3), ("Octave up (+12)", 12), ("Octave down (−12)", -12),
    ]

    var body: some View {
        let s = Scaled(k: k)
        let display = model.arrangement.display(for: program)
        let info = Instruments.info(forProgram: program)
        // Drums have no tab and are notation whatever the mode (`ScoreDocument.build`), so the
        // Display and Tab rows, which could only switch them away from it, are not offered.
        let isDrums = program == NoteEvent.drumProgram

        VStack(alignment: .leading, spacing: s(Self.rowGap)) {
            Text(info.name.uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)

            if !isDrums {
                row("Display") {
                    HStack(spacing: s(2)) {
                        ForEach(PartDisplay.Mode.allCases, id: \.self) { mode in
                            segment(mode.name, isOn: display.mode == mode, isEnabled: mode == .notation || display.tab != nil) {
                                model.setPartMode(mode, program: program)
                            }
                        }
                    }
                }
            }

            row("Clef") {
                menuButton(display.clef.name) { showClefMenu() }
                    .background(AnchorCatcher { clefAnchor = $0 })
            }

            row("Transposition") {
                HStack(spacing: s(6)) {
                    menuButton(Self.transpositionPresets.first { $0.1 == display.transposition }?.0 ?? "Custom") { showTranspositionMenu() }
                        .background(AnchorCatcher { transpositionAnchor = $0 })
                    NumberField(value: Double(display.transposition), range: -36 ... 36, decimals: 0, width: 40) {
                        model.setPartTransposition(Int($0), program: program)
                    }
                }
            }

            if !isDrums {
                row("Tab") {
                    menuButton(display.tab.flatMap { TabTemplate.template(id: $0.template)?.name } ?? "None") { showTemplateMenu() }
                        .background(AnchorCatcher { templateAnchor = $0 })
                }

                if let tab = display.tab {
                    row("Tuning") {
                        menuButton(tab.presetName ?? "Custom") { showTuningMenu(tab) }
                            .background(AnchorCatcher { tuningAnchor = $0 })
                    }

                    // One pitch field per string, bottom tab line first.
                    HStack(spacing: s(4)) {
                        ForEach(Array(tab.tuning.enumerated()), id: \.offset) { string, pitch in
                            PitchField(text: TimeFormat.pitchName(pitch), width: s(34), scale: k) {
                                model.setPartTuning(string: string, pitch: $0, program: program)
                            }
                        }
                    }

                    row("Frets") {
                        NumberField(value: Double(tab.frets), range: 1 ... 36, decimals: 0, width: 40) {
                            model.setPartFrets(Int($0), program: program)
                        }
                    }
                }
            }

            row("Hidden") {
                segment(display.isHidden ? "Hidden" : "Shown", isOn: display.isHidden, isEnabled: true) {
                    model.setPartHidden(!display.isHidden, program: program)
                }
            }
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width), alignment: .leading)
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }

    // MARK: - Pieces

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(8)) {
            TrackedLabel(string: label.uppercased(), em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                         font: Fonts.pillLabel(k), scale: k)
                .foregroundStyle(Theme.textLabel)
                .frame(width: s(Self.labelWidth), alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func segment(_ title: String, isOn: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: isOn, isEnabled: isEnabled, idle: Theme.bgControlAlt, on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.accentText, corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, s(8))
                .frame(height: s(NumberField.height))
        }
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        segment(title, isOn: false, isEnabled: true, action: action)
    }

    // MARK: - Menus

    /// Opens `menu` under `anchor` as the host's child: without key, as `InstrumentPicker` does
    /// from the strip card, or the host would resign key and close under it.
    private func showMenu<Rows: View>(_ menu: PopupMenuPresenter, from anchor: NSView, titles: [String],
                                      @ViewBuilder rows: () -> Rows) {
        guard let window = anchor.window else { return }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        host.child = menu
        menu.show(targetScreenRect: target, in: window, width: PopupMenuPresenter.width(forTitles: titles, scale: k), scale: k,
                  placement: .alignedToTarget, becomesKey: false, rows: rows)
    }

    private func showClefMenu() {
        guard let anchor = clefAnchor else { return }

        let menu = clefMenu
        let model = model
        let program = program

        showMenu(menu, from: anchor, titles: ClefChoice.allCases.map(\.name)) {
            ForEach(ClefChoice.allCases, id: \.self) { clef in
                MenuRow(title: clef.name, isTicked: model.arrangement.display(for: program).clef == clef) {
                    menu.dismiss()
                    model.setPartClef(clef, program: program)
                }
            }
        }
    }

    private func showTranspositionMenu() {
        guard let anchor = transpositionAnchor else { return }

        let menu = transpositionMenu
        let model = model
        let program = program

        showMenu(menu, from: anchor, titles: Self.transpositionPresets.map(\.0)) {
            ForEach(Self.transpositionPresets, id: \.1) { preset in
                MenuRow(title: preset.0, isTicked: model.arrangement.display(for: program).transposition == preset.1) {
                    menu.dismiss()
                    model.setPartTransposition(preset.1, program: program)
                }
            }
        }
    }

    private func showTemplateMenu() {
        guard let anchor = templateAnchor else { return }

        let menu = templateMenu
        let model = model
        let program = program

        showMenu(menu, from: anchor, titles: ["None"] + TabTemplate.all.map(\.name)) {
            MenuRow(title: "None", isTicked: model.arrangement.display(for: program).tab == nil) {
                menu.dismiss()
                model.clearPartTab(program: program)
            }

            MenuSeparator()

            ForEach(TabTemplate.all) { template in
                MenuRow(title: template.name, isTicked: model.arrangement.display(for: program).tab?.template == template.id) {
                    menu.dismiss()
                    model.setPartTab(template: template, preset: template.presets[0], program: program)
                }
            }
        }
    }

    private func showTuningMenu(_ tab: TabSetup) {
        guard let anchor = tuningAnchor, let template = TabTemplate.template(id: tab.template) else { return }

        let menu = tuningMenu
        let model = model
        let program = program

        showMenu(menu, from: anchor, titles: template.presets.map(\.name)) {
            ForEach(template.presets, id: \.name) { preset in
                MenuRow(title: preset.name, isTicked: tab.presetName == preset.name) {
                    menu.dismiss()
                    model.setPartTab(template: template, preset: preset, program: program)
                }
            }
        }
    }
}
