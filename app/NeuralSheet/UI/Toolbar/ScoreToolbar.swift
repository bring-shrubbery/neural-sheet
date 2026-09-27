import AppKit
import NeuralSheetCore
import SwiftUI

/// The Score tab's row above the score (arrangement design §6): Continuous / Pages, A4 / Letter
/// (live in Pages), Parts, the grid and the key shared with the Edit toolbar, then `Sheet…` and
/// Export PDF on the right.
///
/// Same frame as `Toolbar` and `EditToolbar`, so the three tabs' rows sit on the same divider.
struct ScoreToolbar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var partsMenu = PopupMenuPresenter()
    @State private var partsAnchor: NSView?
    @State private var sheetCard = PopupMenuPresenter()
    @State private var sheetAnchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let arrangement = model.arrangement

        VStack(spacing: 0) {
            HStack(spacing: s(Metrics.groupGap)) {
                HStack(spacing: s(2)) {
                    segment("Continuous", isOn: arrangement.layout == .continuous) { model.setScoreLayout(.continuous) }
                    segment("Pages", isOn: arrangement.layout == .pages) { model.setScoreLayout(.pages) }
                }
                .padding(s(2))
                .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))

                HStack(spacing: s(2)) {
                    ForEach(PageSize.allCases, id: \.self) { size in
                        segment(size.name, isOn: arrangement.pageSize == size, isEnabled: arrangement.layout == .pages) {
                            model.setPageSize(size)
                        }
                    }
                }
                .padding(s(2))
                .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))

                // A hidden part loses its name on the page, which is the only way to its card;
                // this menu is how it comes back.
                ToolbarControls.labelButton(k: k, "Parts", tooltip: "Show or hide a part", isEnabled: !model.mixer.entries.isEmpty) {
                    showPartsMenu()
                }
                .background(AnchorCatcher { partsAnchor = $0 })

                GridControls(model: model)

                Spacer(minLength: 0)

                ToolbarControls.labelButton(k: k, "Sheet…", tooltip: "Title, subtitle, composer, arranger, copyright") {
                    showSheetCard()
                }
                .background(AnchorCatcher { sheetAnchor = $0 })

                ToolbarControls.labelButton(k: k, "Export PDF", tooltip: "Write the pages as a PDF (⌥⇧⌘P)",
                                            isEnabled: model.canExport, action: model.exportPDF)
            }
            .frame(height: s(Metrics.buttonHeight))
            .padding(.top, s(7))
            .padding(.bottom, s(8))
            .padding(.horizontal, s(Metrics.paddingSide))

            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
        .frame(height: s(Metrics.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgRoot)
        // Leaving the Score tab takes the row away; a menu or the card left up would outlive
        // what it hangs from.
        .onDisappear {
            partsMenu.dismiss()
            sheetCard.dismiss()
        }
    }

    // MARK: - Pieces

    /// One segment of a two-way tray, the live one on the accent fill: the tool switcher's
    /// shape with a label, 4 short of the row's button height to fit inside the tray's padding.
    private func segment(_ title: String, isOn: Bool, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Metrics.buttonPadX))
                .frame(height: s(Metrics.buttonHeight - 4))
        }
    }

    // MARK: - Menus

    /// Every instrument in the mix, ticked while its part is shown; a choice flips it.
    private func showPartsMenu() {
        guard let anchor = partsAnchor else { return }

        let menu = partsMenu
        let model = model
        let entries = model.mixer.entries
        let width = PopupMenuPresenter.width(forTitles: entries.map(\.info.name), scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(entries, id: \.program) { entry in
                let hidden = model.arrangement.display(for: entry.program).isHidden

                MenuRow(title: entry.info.name, isTicked: !hidden) {
                    menu.dismiss()
                    model.setPartHidden(!hidden, program: entry.program)
                }
            }
        }
    }

    /// The sheet card under its button, in a menu panel that takes key for its fields.
    private func showSheetCard() {
        guard let anchor = sheetAnchor else { return }

        let card = sheetCard
        let model = model

        card.show(from: anchor, width: SheetCard.width * k, scale: k) {
            SheetCard(model: model, host: card)
        }
    }
}
