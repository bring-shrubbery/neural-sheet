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

    /// Written = sounding + semitones. Computed, so the names are in the language in effect.
    static var transpositionPresets: [(String, Int)] {
        [
            (String(localized: "None", comment: "Part card: no transposition"), 0),
            ("B♭ (+2)", 2),
            (String(localized: "B♭ tenor (+14)", comment: "Part card: a transposition, as a tenor saxophone reads"), 14),
            (String(localized: "E♭ alto (+9)", comment: "Part card: a transposition, as an alto saxophone reads"), 9),
            (String(localized: "E♭ baritone (+21)", comment: "Part card: a transposition, as a baritone saxophone reads"), 21),
            ("F (+7)", 7),
            ("A (+3)", 3),
            (String(localized: "Octave up (+12)", comment: "Part card: written an octave above the sound"), 12),
            (String(localized: "Octave down (−12)", comment: "Part card: written an octave below the sound"), -12),
        ]
    }

    var body: some View {
        let s = Scaled(k: k)
        let display = model.arrangement.display(for: program)
        let info = Instruments.info(forProgram: program)
        // Drums have no tab and are notation whatever the mode (`ScoreDocument.build`), so the
        // Display and Tab rows, which could only switch them away from it, are not offered.
        let isDrums = program == NoteEvent.drumProgram

        VStack(alignment: .leading, spacing: s(Self.rowGap)) {
            Text(info.localizedName.localizedUppercase)
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: info.localizedName))
                .accessibilityAddTraits(.isHeader)

            if !isDrums {
                row("Display") {
                    HStack(spacing: s(2)) {
                        ForEach(PartDisplay.Mode.allCases, id: \.self) { mode in
                            segment(mode.localizedName, isOn: display.mode == mode, isEnabled: true) {
                                model.setPartMode(mode, program: program)
                            }
                        }
                    }
                }
            }

            row("Clef") {
                menuButton(display.clef.localizedName) { showClefMenu() }
                    .background(AnchorCatcher { clefAnchor = $0 })
                    .accessibilityLabel(Text(AccessibilityText.clef))
                    .accessibilityValue(Text(verbatim: display.clef.localizedName))
            }

            row("Transposition") {
                HStack(spacing: s(6)) {
                    menuButton(Self.transpositionPresets.first { $0.1 == display.transposition }?.0 ?? Self.custom) { showTranspositionMenu() }
                        .background(AnchorCatcher { transpositionAnchor = $0 })
                        .accessibilityLabel(Text(AccessibilityText.transposition))
                        .accessibilityValue(Text(verbatim: Self.transpositionPresets.first { $0.1 == display.transposition }?.0 ?? Self.custom))
                    NumberField(value: Double(display.transposition), range: -36 ... 36, decimals: 0, width: 40) {
                        model.setPartTransposition(Int($0), program: program)
                    }
                    .accessibilityLabel(Text(AccessibilityText.transpositionSemitones))
                }
            }

            if !isDrums {
                row("Tab") {
                    menuButton(display.tab.flatMap { TabTemplate.template(id: $0.template)?.localizedName } ?? Self.none) { showTemplateMenu() }
                        .background(AnchorCatcher { templateAnchor = $0 })
                        .accessibilityLabel(Text(AccessibilityText.tab))
                }

                if let tab = display.tab {
                    row("Tuning") {
                        menuButton(tab.presetName.map(CoreNames.localized) ?? Self.custom) { showTuningMenu(tab) }
                            .background(AnchorCatcher { tuningAnchor = $0 })
                            .accessibilityLabel(Text(AccessibilityText.tuning))
                    }

                    // One pitch field per string, bottom tab line first.
                    HStack(spacing: s(4)) {
                        ForEach(Array(tab.tuning.enumerated()), id: \.offset) { string, pitch in
                            PitchField(text: TimeFormat.pitchName(pitch), width: s(34), scale: k) {
                                model.setPartTuning(string: string, pitch: $0, program: program)
                            }
                            .accessibilityLabel(Text(AccessibilityText.stringTuning(tab.tuning.count - string)))
                        }
                    }

                    row("Frets") {
                        NumberField(value: Double(tab.frets), range: 1 ... 36, decimals: 0, width: 40) {
                            model.setPartFrets(Int($0), program: program)
                        }
                        .accessibilityLabel(Text(AccessibilityText.frets))
                    }
                }
            }

            row("Hidden") {
                segment(display.isHidden ? Self.hidden : Self.shown, isOn: display.isHidden, isEnabled: true) {
                    model.setPartHidden(!display.isHidden, program: program)
                }
                .accessibilityLabel(Text(AccessibilityText.hidden))
                .accessibilityValue(Text(verbatim: display.isHidden ? Self.hidden : Self.shown))
            }
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width), alignment: .leading)
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }

    // MARK: - Pieces

    private static var custom: String { String(localized: "Custom", comment: "Part card: a transposition or tuning that is none of the presets") }
    private static var none: String { String(localized: "None", comment: "Part card: no tab") }
    private static var hidden: String { String(localized: "Hidden", comment: "Part card: the part is left off the score") }
    private static var shown: String { String(localized: "Shown", comment: "Part card: the part is on the score") }

    private func row<Control: View>(_ label: LocalizedStringResource, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(8)) {
            TrackedLabel(string: String(localized: label).localizedUppercase, em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                         font: Fonts.pillLabel(k), scale: k)
                .foregroundStyle(Theme.textLabel)
                .frame(width: s(Self.labelWidth), alignment: .leading)
                // The controls carry the row's name (a11y design §2).
                .accessibilityHidden(true)
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

        showMenu(menu, from: anchor, titles: ClefChoice.allCases.map(\.localizedName)) {
            ForEach(ClefChoice.allCases, id: \.self) { clef in
                MenuRow(title: clef.localizedName, isTicked: model.arrangement.display(for: program).clef == clef) {
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

        showMenu(menu, from: anchor, titles: [Self.none] + TabTemplate.all.map(\.localizedName)) {
            MenuRow(title: Self.none, isTicked: model.arrangement.display(for: program).tab == nil) {
                menu.dismiss()
                model.clearPartTab(program: program)
            }

            MenuSeparator()

            ForEach(TabTemplate.all) { template in
                MenuRow(title: template.localizedName, isTicked: model.arrangement.display(for: program).tab?.template == template.id) {
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

        showMenu(menu, from: anchor, titles: template.presets.map(\.localizedName)) {
            ForEach(template.presets, id: \.name) { preset in
                MenuRow(title: preset.localizedName, isTicked: tab.presetName == preset.name) {
                    menu.dismiss()
                    model.setPartTab(template: template, preset: preset, program: program)
                }
            }
        }
    }
}
