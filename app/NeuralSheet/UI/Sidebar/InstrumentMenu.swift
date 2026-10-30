import AppKit
import NeuralSheetCore
import SwiftUI

/// The picker behind the sidebar's "+" (§3.3): every instrument the model can name, ticked where
/// it is selected, with "Automatic" at the top for the default of letting the model choose.
///
/// A multi-select, so it stays open across clicks and every row carries a box whether ticked or
/// not. Shown in a popover off the "+" (native chrome design §4), which closes it on Escape and on
/// a click outside; it shares the menus' metrics and tick box.
struct InstrumentMenu: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    private static var title: String {
        String(localized: "ADD INSTRUMENT", comment: "The sidebar's instrument picker: its header")
    }

    private static var footer: String {
        String(localized: "TICK TO INCLUDE IN TRANSCRIPTION", comment: "The sidebar's instrument picker: its footer")
    }
    private static let footerTracking: Double = 0.04

    /// One offer in the list. No group means "Automatic", which is the empty selection.
    fileprivate struct Entry: Identifiable {
        let name: String
        let group: InstrumentGroup?

        var id: Int32 { group?.rawValue ?? -1 }
    }

    /// "Automatic" first -- nothing selected means the model chooses, which is worth naming rather
    /// than leaving as the state you get by unticking everything -- then the 35 named groups in
    /// enumerator order.
    fileprivate static let entries: [Entry] =
        [Entry(name: String(localized: RetranscribeButton.automatic), group: nil)]
        + Instruments.all.map { Entry(name: $0.localizedName, group: $0.group) }

    var body: some View {
        let s = Scaled(k: k)
        let corner = s(MenuMetrics.corner)
        let selected = model.selectedGroups

        VStack(spacing: 0) {
            Text(Self.title)
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                        pointSize: Fonts.Size.sectionHeader,
                                        scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s(MenuMetrics.padX))
                .frame(height: s(MenuMetrics.headerHeight))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.divStrong).frame(height: k)
                }
                .accessibilityAddTraits(.isHeader)

            ScrollView(.vertical) {
                InstrumentMenuRows(model: model, selected: selected)
                    .padding(.vertical, s(MenuMetrics.listPadY))
            }
            .scrollBounceBehavior(.basedOnSize)
            // JUCE's own scrollbar, which the 36 rows always call for: the thumb in
            // `checkboxBorder`, the rows narrowed by its 8 px.
            .legacyScrollbar(thumb: Theme.checkboxBorder)
            .frame(height: min(s(MenuMetrics.listMaxHeight), listHeight(s)))

            Text(Self.footer)
                .font(Fonts.meta(k))
                .kerning(Fonts.tracking(Self.footerTracking, pointSize: Fonts.Size.meta, scale: k))
                .foregroundStyle(Theme.textFaintest)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s(MenuMetrics.padX))
                .frame(height: s(MenuMetrics.footerHeight))
                // Rounded along the bottom only, so its fill follows the panel's corners instead
                // of squaring them off.
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner, style: .circular)
                        .fill(Theme.popupFooterBg))
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divStrong).frame(height: k)
                }
        }
        .frame(width: s(MenuMetrics.width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.title))
    }

    private func listHeight(_ s: Scaled) -> CGFloat {
        s(CGFloat(Self.entries.count) * MenuMetrics.rowHeight + 2 * MenuMetrics.listPadY)
    }

    /// The rows, inset on the trailing edge by whatever the scrollbar takes.
    private struct InstrumentMenuRows: View {
        let model: AppModel
        let selected: [InstrumentGroup]

        @Environment(\.legacyScrollbarInset) private var scrollbarInset

        var body: some View {
            VStack(spacing: 0) {
                ForEach(InstrumentMenu.entries) { entry in
                    let ticked = entry.group.map(selected.contains) ?? selected.isEmpty

                    InstrumentMenuRow(title: entry.name, isTicked: ticked) {
                        if let group = entry.group {
                            model.setSelected(group, !ticked)
                        } else {
                            model.clearSelection()
                        }
                    }
                }
            }
            .padding(.trailing, scrollbarInset)
        }
    }
}

/// One row of the picker: the name and, at the right-hand end, a box that is drawn whether or not
/// it is ticked -- every row here is a toggle.
private struct InstrumentMenuRow: View {
    let title: String
    let isTicked: Bool
    let action: () -> Void

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: 0) {
            Text(title)
                .font(isTicked ? Fonts.menuItemTicked(k) : Fonts.menuItem(k))
                .foregroundStyle(isTicked ? Theme.popupItemTicked : Theme.popupItem)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: s(MenuMetrics.padX))

            MenuCheckbox(isTicked: isTicked)
        }
        .padding(.horizontal, s(MenuMetrics.padX))
        .frame(height: s(MenuMetrics.rowHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Theme.popupRowHover : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        // A ticked row is a selected button to VoiceOver, and the keyboard can tick it (a11y
        // design §2).
        .accessibleButton(Text(verbatim: title), isSelected: isTicked, action: action)
        .accessibilityValue(Text(isTicked ? AccessibilityText.ticked : AccessibilityText.unticked))
    }
}

#Preview("Instrument menu") {
    let model = AppModel()

    return InstrumentMenu(model: model)
        .onAppear {
            model.setSelected(.acousticPiano, true)
            model.setSelected(.drums, true)
        }
}
