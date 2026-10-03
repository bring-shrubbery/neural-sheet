import AppKit
import NeuralSheetCore
import SwiftUI

/// The ruler's card (tempo map design §4): a right-click on the ruler, or a click on a change's
/// flag, opens the tempo and the meter of the segment under the pointer in a floating panel, the
/// note card's style, with the command that adds a change at that bar or removes the one there.
/// It reads the grid live, so adding a change turns its button into Remove.
struct RulerTempoCard: View {
    let model: AppModel
    /// The bar under the pointer.
    let bar: Int
    /// The panel this card is in, so the TIME menus open as its children.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k

    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)
        let grid = model.editor.grid
        let segment = grid.segment(atBar: bar)
        let bar = bar

        VStack(alignment: .leading, spacing: 0) {
            Text("Tempo from bar \(max(1, segment.startBar))".uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)

            VStack(spacing: s(SelectionFields.rowGap)) {
                row("Tempo") {
                    NumberField(value: segment.bpm, range: TempoGrid.minBpm ... TempoGrid.maxBpm, decimals: 1, width: 56) {
                        model.setTempo($0, atBar: bar)
                    }
                    .tooltip("Quarter notes a minute")
                }

                row("Time") {
                    TimeSignatureMenus(meter: segment.timeSignature, host: host) { model.setTimeSignature($0, atBar: bar) }
                }
            }
            .padding(.top, s(8))

            if grid.isChange(atBar: bar) {
                actionButton("Remove Tempo Change", foreground: Theme.warn) {
                    model.removeTempoChange(atBar: bar)
                    host.dismiss()
                }
                .padding(.top, s(10))
            } else if bar > 1 {
                actionButton("Add Tempo Change at Bar \(bar)", foreground: Theme.textButton) {
                    model.addTempoChange(atBar: bar)
                }
                .padding(.top, s(10))
            }
        }
        .padding(s(Self.padding))
        .frame(width: s(NoteCard.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }

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

    private func actionButton(_ title: String, foreground: Color, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
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
