import AppKit
import NeuralSheetCore
import SwiftUI

/// TIME (tempo map design §4): the numerator and the denominator as two label buttons, each
/// opening its menu. Shared by the toolbar and the ruler's card; in the card the menus open as
/// the card's children (`host`), so choosing from one does not close the card.
struct TimeSignatureMenus: View {
    let meter: TimeSignature
    var host: PopupMenuPresenter? = nil
    let onChange: (TimeSignature) -> Void

    @Environment(\.uiScale) private var k
    @State private var numeratorMenu = PopupMenuPresenter()
    @State private var numeratorAnchor: NSView?
    @State private var denominatorMenu = PopupMenuPresenter()
    @State private var denominatorAnchor: NSView?

    /// What most music is in, at the top of the numerator menu; the rest follow in order.
    static let commonNumerators = [4, 3, 2, 6, 5, 7, 9, 12]
    /// The toolbar's denominators; a file's 32 still reads.
    static let denominators = [1, 2, 4, 8, 16]

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: s(2)) {
            ToolbarControls.labelButton(k: k, "\(meter.numerator)", tooltip: "Beats in a bar") { showNumeratorMenu() }
                .background(AnchorCatcher { numeratorAnchor = $0 })

            Text("/")
                .font(Fonts.buttonLabel(k))
                .foregroundStyle(Theme.textLabel)

            ToolbarControls.labelButton(k: k, "\(meter.denominator)", tooltip: "The note that counts as a beat") { showDenominatorMenu() }
                .background(AnchorCatcher { denominatorAnchor = $0 })
        }
        // A menu left up would outlive the button it hangs from, with its monitors and observers.
        .onDisappear {
            numeratorMenu.dismiss()
            denominatorMenu.dismiss()
        }
    }

    private func showNumeratorMenu() {
        let rest = TimeSignature.numerators.filter { !Self.commonNumerators.contains($0) }

        show(numeratorMenu, from: numeratorAnchor, titles: (Self.commonNumerators + rest).map(String.init)) { menu in
            ForEach(Self.commonNumerators, id: \.self) { numerator in
                row(menu, numerator: numerator)
            }

            MenuSeparator()

            ForEach(rest, id: \.self) { numerator in
                row(menu, numerator: numerator)
            }
        }
    }

    private func row(_ menu: PopupMenuPresenter, numerator: Int) -> MenuRow {
        MenuRow(title: "\(numerator)", isTicked: meter.numerator == numerator) {
            menu.dismiss()
            onChange(TimeSignature(numerator: numerator, denominator: meter.denominator))
        }
    }

    private func showDenominatorMenu() {
        show(denominatorMenu, from: denominatorAnchor, titles: Self.denominators.map(String.init)) { menu in
            ForEach(Self.denominators, id: \.self) { denominator in
                MenuRow(title: "\(denominator)", isTicked: meter.denominator == denominator) {
                    menu.dismiss()
                    onChange(TimeSignature(numerator: meter.numerator, denominator: denominator))
                }
            }
        }
    }

    /// Under its button; a child of the card when there is one, which keeps the key.
    private func show<Rows: View>(_ menu: PopupMenuPresenter, from anchor: NSView?, titles: [String],
                                  @ViewBuilder rows: (PopupMenuPresenter) -> Rows) {
        guard let anchor, let window = anchor.window else { return }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        host?.child = menu
        menu.show(targetScreenRect: target, in: window, width: width, scale: k, placement: .alignedToTarget,
                  becomesKey: host == nil) {
            rows(menu)
        }
    }
}
