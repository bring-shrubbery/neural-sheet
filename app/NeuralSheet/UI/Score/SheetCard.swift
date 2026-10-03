import AppKit
import NeuralSheetCore
import SwiftUI

/// The sheet's title block (arrangement design §6): title, subtitle, composer, arranger and the
/// copyright footer, then the measure numbers, the part names, the tempo mark and the chord
/// symbols as ticks. Every
/// change goes to the model as a whole `SheetMetadata`. Shown in the Score toolbar's menu panel
/// under `Sheet…`, which takes key so the fields can be typed in; the rows are sized so the whole
/// card fits the panel's list without scrolling.
struct SheetCard: View {
    let model: AppModel
    /// The panel this card is in.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k

    static let width: CGFloat = PartDisplayCard.width
    private static let padY: CGFloat = 4
    private static let rowGap: CGFloat = 8
    private static let labelWidth: CGFloat = 84
    private static let headerHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)
        let sheet = model.arrangement.sheet

        VStack(alignment: .leading, spacing: s(Self.rowGap)) {
            Text("SHEET")
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .frame(height: s(Self.headerHeight), alignment: .leading)

            // The title's placeholder is what the header prints without one: the take's name,
            // or "Untitled".
            row("Title") {
                SheetField(text: sheet.title ?? "", placeholder: SheetMetadata().resolvedTitle(takeName: model.droppedFileName), scale: k) { text in
                    update { $0.title = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text }
                }
            }

            row("Subtitle") {
                SheetField(text: sheet.subtitle, placeholder: "", scale: k) { text in update { $0.subtitle = text } }
            }

            row("Composer") {
                SheetField(text: sheet.composer, placeholder: "", scale: k) { text in update { $0.composer = text } }
            }

            row("Arranger") {
                SheetField(text: sheet.arranger, placeholder: "", scale: k) { text in update { $0.arranger = text } }
            }

            row("Copyright") {
                SheetField(text: sheet.copyright, placeholder: "", scale: k) { text in update { $0.copyright = text } }
            }

            // Stacked as a menu's rows are, without the fields' gap, so the fourth (chord symbols
            // design §2) still fits the panel's list without scrolling.
            VStack(spacing: 0) {
                tick("Measure numbers", isOn: sheet.showsMeasureNumbers) { update { $0.showsMeasureNumbers.toggle() } }
                tick("Part names", isOn: sheet.showsPartNames) { update { $0.showsPartNames.toggle() } }
                tick("Tempo mark", isOn: sheet.showsTempo) { update { $0.showsTempo.toggle() } }
                tick("Show chords", isOn: sheet.showsChords) { update { $0.showsChords.toggle() } }
            }
        }
        .padding(.horizontal, s(MenuMetrics.padX))
        .padding(.vertical, s(Self.padY))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    /// A copy of the sheet, changed, back to the model.
    private func update(_ change: (inout SheetMetadata) -> Void) {
        var sheet = model.arrangement.sheet
        change(&sheet)
        model.setSheet(sheet)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(8)) {
            TrackedLabel(string: label.uppercased(), em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                         font: Fonts.pillLabel(k), scale: k)
                .foregroundStyle(Theme.textLabel)
                .frame(width: s(Self.labelWidth), alignment: .leading)
            control()
        }
    }

    /// A menu row's shape with the tick box at the end, for a switch.
    private func tick(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(isOn ? Fonts.menuItemTicked(k) : Fonts.menuItem(k))
                .foregroundStyle(isOn ? Theme.popupItemTicked : Theme.popupItem)
                .lineLimit(1)

            Spacer(minLength: s(MenuMetrics.padX))

            MenuCheckbox(isTicked: isOn)
        }
        .frame(height: s(NumberField.height))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .pointerStyle(.link)
        .accessibilityAddTraits(.isButton)
    }
}

/// A line of text in the note card's field chrome, left-aligned in the sans: commits on Return
/// or focus loss, and Return gives the keyboard back so Space is the transport's again.
private struct SheetField: View {
    let text: String
    let placeholder: String
    let scale: CGFloat
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var lastCommitted: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(Theme.textFaint))
            .textFieldStyle(.plain)
            .font(Fonts.sans(11, weight: 500, scale: scale))
            .foregroundStyle(Theme.textStrong)
            .focused($isFocused)
            .padding(.horizontal, 6 * scale)
            .frame(maxWidth: .infinity)
            .frame(height: NumberField.height * scale)
            .background(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: scale))
            .onAppear { draft = text }
            .onChange(of: text) { _, new in
                lastCommitted = nil

                if !isFocused { draft = new }
            }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit {
                commit()
                isFocused = false
            }
    }

    /// Return and the focus loss it causes both come through here; the second sees the same
    /// entry and commits nothing more.
    private func commit() {
        guard draft != text, draft != lastCommitted else { return }

        lastCommitted = draft
        onCommit(draft)
    }
}
