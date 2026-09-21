import AppKit
import NeuralSheetCore
import SwiftUI

/// The strip's card (region design §6.1): a right-click on a strip in the Edit tab opens the
/// whole-instrument commands at the pointer -- change every note to another instrument (the
/// merge, when that instrument is in the mix), split at a pitch, or delete the instrument. The
/// same floating panel as the roll's note card, the same rows as the inspector.
struct InstrumentCard: View {
    let model: AppModel
    let entry: InstrumentEntry
    /// The panel this card is in, so the instrument menus open as its children and a command
    /// can close it.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k
    @State private var changeMenu = PopupMenuPresenter()
    @State private var changeAnchor: NSView?
    @State private var sendMenu = PopupMenuPresenter()
    @State private var sendAnchor: NSView?
    @State private var splitPitch: Int
    @State private var sendingAbove = true
    @State private var destination: Int?

    static let width: CGFloat = NoteCard.width
    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let chipSize: CGFloat = 10
    private static let chipCorner: CGFloat = 2.5

    init(model: AppModel, entry: InstrumentEntry, host: PopupMenuPresenter) {
        self.model = model
        self.entry = entry
        self.host = host
        // The midpoint of the part's range, rounded down; middle C for a strip with no notes.
        _splitPitch = State(initialValue: entry.isPlaceholder ? 60 : (entry.lowestPitch + entry.highestPitch) / 2)
    }

    var body: some View {
        let s = Scaled(k: k)
        let colour = Color(.sRGB, red: entry.info.colour.r, green: entry.info.colour.g, blue: entry.info.colour.b, opacity: entry.info.colour.a)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: s(8)) {
                let shape = RoundedRectangle(cornerRadius: s(Self.chipCorner), style: .circular)

                ZStack {
                    shape.fill(Theme.chipFill(colour))
                    shape.strokeBorder(Theme.chipBorder(colour), lineWidth: k)
                }
                .frame(width: s(Self.chipSize), height: s(Self.chipSize))

                Text(entry.info.name.uppercased())
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.popupTitle)
                    .lineLimit(1)
            }
            .frame(height: s(Self.labelHeight), alignment: .leading)

            VStack(spacing: s(SelectionFields.rowGap)) {
                row("Change to") {
                    popupButton(title: "—") { changeAnchor = $0 } action: {
                        guard let changeAnchor else { return }

                        InstrumentPicker.show(changeMenu, from: changeAnchor, host: host, model: model, current: [],
                                              excluding: entry.program, scale: k) { program in
                            model.reassignInstrument(entry.program, to: program)
                            host.dismiss()
                        }
                    }
                }

                row("Split at") {
                    HStack(spacing: s(6)) {
                        PitchField(text: TimeFormat.pitchName(splitPitch), width: s(48), scale: k) { splitPitch = $0 }
                        sideToggle
                    }
                }

                row("Send to") {
                    popupButton(title: destination.map { Instruments.info(forProgram: $0).name } ?? "—") { sendAnchor = $0 } action: {
                        guard let sendAnchor else { return }

                        InstrumentPicker.show(sendMenu, from: sendAnchor, host: host, model: model,
                                              current: destination.map { [$0] } ?? [], excluding: entry.program, scale: k) { program in
                            destination = program
                        }
                    }
                }
            }
            .padding(.top, s(8))

            HStack(spacing: s(6)) {
                actionButton("Split", isEnabled: destination != nil, foreground: Theme.textButton) {
                    if let destination {
                        model.splitInstrument(entry.program, atPitch: splitPitch, sendingAbove: sendingAbove, to: destination)
                    }

                    host.dismiss()
                }

                actionButton("Delete instrument", isEnabled: true, foreground: Theme.warn) {
                    model.deleteInstrument(entry.program)
                    host.dismiss()
                }
            }
            .padding(.top, s(10))
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }

    // MARK: - Pieces

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(SelectionFields.rowHeight))
    }

    /// The inspector's instrument button: a flat button whose anchor the menu opens from.
    private func popupButton(title: String, anchor: @escaping (NSView) -> Void, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .lineLimit(1)
                .frame(width: s(120), height: s(NumberField.height), alignment: .leading)
                .padding(.horizontal, s(6))
        }
        .background(AnchorCatcher(found: anchor))
    }

    /// Above / Below as a two-segment pair, the live side on the accent fill.
    private var sideToggle: some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(2)) {
            segment("Above", isOn: sendingAbove) { sendingAbove = true }
            segment("Below", isOn: !sendingAbove) { sendingAbove = false }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular).fill(Theme.bgControlAlt))
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: isOn, idle: .clear, on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.accentText,
                          corner: s(NumberField.corner - 1), action: action) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .fixedSize()
                .padding(.horizontal, s(6))
                .frame(height: s(NumberField.height - 4))
        }
    }

    private func actionButton(_ title: String, isEnabled: Bool, foreground: Color, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isEnabled: isEnabled, idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: foreground, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(10))
                .frame(height: s(NumberField.height))
        }
    }
}
