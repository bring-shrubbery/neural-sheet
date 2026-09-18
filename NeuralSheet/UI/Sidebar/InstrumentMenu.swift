import AppKit
import NeuralSheetCore
import SwiftUI

/// The picker behind the sidebar's "+" (§3.3): every instrument the model can name, ticked where
/// it is selected, with "Automatic" at the top for the default of letting the model choose.
///
/// A panel of its own rather than a `MenuPanel`: the selection is a multi-select, so it stays open
/// across clicks, every row carries a box whether ticked or not, and its header and footer are
/// ruled and set differently from the popup menus'. It shares the menus' metrics, surface and
/// tick box.
///
/// `InstrumentMenuOverlay` covers the whole main view: everything outside the panel is the scrim
/// that closes it, and so is Escape. The main view puts it in its root stack while
/// `model.isInstrumentMenuOpen`.
struct InstrumentMenuOverlay: View {
    let model: AppModel
    /// Where the sidebar sits in the main view, in authored points: under the top bar. The panel
    /// hangs off the sidebar's anchor, `(width - 10, 33)` from there.
    var sidebarOrigin: CGPoint = CGPoint(x: 0, y: 54)

    @Environment(\.uiScale) private var k

    @State private var keyMonitor: Any?

    var body: some View {
        let s = Scaled(k: k)
        let anchorX = sidebarOrigin.x + SidebarMetrics.width - SidebarMetrics.menuAnchorRight
        let anchorY = sidebarOrigin.y + SidebarMetrics.menuAnchorTop

        ZStack(alignment: .topLeading) {
            // The scrim: nothing to see, everything to click.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }

            InstrumentMenu(model: model)
                .padding(.leading, s(anchorX - MenuMetrics.width))
                .padding(.top, s(anchorY))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private func close() {
        model.isInstrumentMenuOpen = false
    }

    // MARK: - Escape

    /// A local monitor rather than focus: the menu is on screen only while it is open, and Escape
    /// has to reach it whatever else in the window has the keyboard (§11.2).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }

            close()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// The panel itself: header, the scrolling row list, footer, on the popup surface with the menus'
/// drop shadow (34 / (0, 14)).
struct InstrumentMenu: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    private static let title = "ADD INSTRUMENT"
    private static let footer = "TICK TO INCLUDE IN TRANSCRIPTION"
    private static let footerTracking: Double = 0.04

    /// One offer in the list. No group means "Automatic", which is the empty selection.
    private struct Entry: Identifiable {
        let name: String
        let group: InstrumentGroup?

        var id: Int32 { group?.rawValue ?? -1 }
    }

    /// "Automatic" first -- nothing selected means the model chooses, which is worth naming rather
    /// than leaving as the state you get by unticking everything -- then the 35 named groups in
    /// enumerator order.
    private static let entries: [Entry] =
        [Entry(name: "Automatic (any instrument)", group: nil)]
        + Instruments.all.map { Entry(name: $0.name, group: $0.group) }

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

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Self.entries) { entry in
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
                .padding(.vertical, s(MenuMetrics.listPadY))
            }
            .scrollBounceBehavior(.basedOnSize)
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
        .popupSurface(corner: corner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }

    private func listHeight(_ s: Scaled) -> CGFloat {
        s(CGFloat(Self.entries.count) * MenuMetrics.rowHeight + 2 * MenuMetrics.listPadY)
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
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isTicked ? "ticked" : "unticked")
    }
}

#Preview("Instrument menu") {
    let model = AppModel()

    return ZStack(alignment: .topLeading) {
        Theme.bgRoot

        HStack(spacing: 0) {
            Sidebar(model: model)
            Spacer()
        }
        .padding(.top, 54)

        InstrumentMenuOverlay(model: model)
    }
    .frame(width: 640, height: 500)
    .onAppear {
        model.isInstrumentMenuOpen = true
        model.setSelected(.acousticPiano, true)
        model.setSelected(.drums, true)
    }
}
