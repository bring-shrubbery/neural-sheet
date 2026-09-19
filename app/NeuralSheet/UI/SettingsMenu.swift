import AppKit
import NeuralSheetCore
import SwiftUI

/// The gear's menu (`NeuralNoteMainView::_buildSettingsMenu`, inventory §11.3):
///
/// 1. Reset Zoom
/// 2. Show Tooltips (ticked while on; persisted)
/// 3. MIDI export: too many instruments ▸ Reuse the last channels / Drop the extra instruments
/// 4. ——
/// 5. Check for updates
///
/// No Window size submenu any more: the window is an ordinary resizable one.
///
/// A `PopupMenu` in its own window, as the original: aligned under the gear's left edge, which
/// puts it past the window's right edge, with each submenu in a second window beside the row the
/// pointer opened it from. Every tick is read off the model as the menu opens, so a state changed
/// elsewhere shows the moment it does; nothing is drawn for an unticked row, because half the rows
/// are actions, and no arrow marks a submenu row -- the LookAndFeel drew none. Any click on a row
/// closes the menu; a click elsewhere, Escape and the app deactivating close it without one.
@MainActor final class SettingsMenuController {
    private let menu = PopupMenuPresenter()
    private var submenu: Submenu?
    private weak var window: NSWindow?
    private let scale: CGFloat = 1
    private var model: AppModel?

    /// `TopBar`'s settings button: 32 wide at the right padding of 14, in the 30 px control row
    /// that sits at y 11. The x is from the window's right edge.
    static let gearSize = CGSize(width: 32, height: 30)
    static let gearInsetRight: CGFloat = 14
    static let gearTop: CGFloat = 11

    enum Submenu {
        case midiOverflow

        /// The row the submenu hangs off, counting from the top of the list.
        var rowIndex: Int {
            switch self {
            case .midiOverflow: 2
            }
        }
    }

    private static let mainTitles = [
        "Reset Zoom", "Show Tooltips", "MIDI export: too many instruments", "Check for updates",
    ]

    private static let overflowChoices: [(mode: MidiOverflowMode, title: String)] = [
        (.reuseChannels, "Reuse the last channels"),
        (.dropExtraInstruments, "Drop the extra instruments"),
    ]

    var isOpen: Bool { menu.panel != nil }

    /// Opens the menu under the gear.
    ///
    /// - Parameter window: The window the gear is in; the menu is placed from its content frame.
    func open(in window: NSWindow, model: AppModel) {
        self.window = window
        self.model = model
        submenu = nil

        let width = PopupMenuPresenter.width(forTitles: Self.mainTitles, scale: scale)
        let target = window.convertToScreen(Self.gearWindowRect(in: window))

        menu.onDismiss = { [weak self] in self?.submenu = nil }
        menu.show(targetScreenRect: target, in: window, width: width, scale: scale, placement: .alignedToTarget,
                  becomesKey: true) {
            mainRows(model: model)
        }
    }

    func close() {
        menu.dismiss()
    }

    // MARK: - Rows

    @ViewBuilder
    private func mainRows(model: AppModel) -> some View {
        MenuRow(title: Self.mainTitles[0]) { [weak self] in
            self?.close()
            model.resetZoom()
        }
        .onHover { [weak self] in self?.hoverPlainRow($0) }

        MenuRow(title: Self.mainTitles[1], isTicked: model.settings.tooltipsVisible) { [weak self] in
            self?.close()
            model.settings.tooltipsVisible.toggle()
        }
        .onHover { [weak self] in self?.hoverPlainRow($0) }

        SubmenuRowView(title: Self.mainTitles[2], isOpen: submenu == .midiOverflow) { [weak self] in
            self?.openSubmenu(.midiOverflow)
        }

        MenuSeparator()

        MenuRow(title: Self.mainTitles[3]) { [weak self] in
            self?.close()
            model.checkForUpdates(explicit: true)
        }
        .onHover { [weak self] in self?.hoverPlainRow($0) }
    }

    /// Entering a plain row closes whichever submenu was open, as `PopupMenu` does.
    private func hoverPlainRow(_ hovering: Bool) {
        guard hovering, submenu != nil, let model else { return }

        submenu = nil
        menu.child?.dismiss()
        menu.child = nil
        menu.refresh { mainRows(model: model) }
    }

    // MARK: - Submenus

    /// Opens one submenu beside its row, as hovering the row does.
    func openSubmenu(_ which: Submenu) {
        guard submenu != which, let window, let model, let panel = menu.panel else { return }

        submenu = which
        menu.refresh { mainRows(model: model) }

        let titles = Self.overflowChoices.map(\.title)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: scale)
        let row = Self.rowScreenRect(index: which.rowIndex, in: panel, scale: scale)
        let child = PopupMenuPresenter()

        menu.child?.dismiss()
        menu.child = child

        child.show(targetScreenRect: row, in: window, width: width, scale: scale, placement: .besideTarget,
                   becomesKey: false) {
            submenuRows(which, model: model)
        }
    }

    @ViewBuilder
    private func submenuRows(_ which: Submenu, model: AppModel) -> some View {
        switch which {
        case .midiOverflow:
            ForEach(Self.overflowChoices, id: \.mode) { [weak self] choice in
                MenuRow(title: choice.title, isTicked: model.settings.midiOverflowMode == choice.mode) {
                    self?.close()
                    model.settings.midiOverflowMode = choice.mode
                }
            }
        }
    }

    // MARK: - Geometry

    /// The gear's rectangle in the window's content, in AppKit's bottom-up window coordinates.
    private static func gearWindowRect(in window: NSWindow) -> CGRect {
        let content = window.contentView?.bounds.size ?? MainWindowController.defaultContentSize

        return CGRect(x: content.width - gearInsetRight - gearSize.width,
                      y: content.height - gearTop - gearSize.height,
                      width: gearSize.width,
                      height: gearSize.height)
    }

    /// A row's screen rectangle inside a menu panel: the rows start under the list padding.
    private static func rowScreenRect(index: Int, in panel: NSWindow, scale: CGFloat) -> CGRect {
        let frame = panel.frame
        let top = frame.maxY - (MenuMetrics.listPadY + CGFloat(index) * MenuMetrics.rowHeight) * scale

        return CGRect(x: frame.minX, y: top - MenuMetrics.rowHeight * scale, width: frame.width,
                      height: MenuMetrics.rowHeight * scale)
    }
}

/// A row that opens a submenu: the title alone -- the LookAndFeel's `drawPopupMenuItemWithOptions`
/// drew no arrow. Highlighted while the pointer is on it and for as long as its submenu is open, so
/// the pointer can leave for the submenu without the row going dark.
private struct SubmenuRowView: View {
    let title: String
    let isOpen: Bool
    let open: () -> Void

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    var body: some View {
        let s = Scaled(k: k)

        Text(title)
            .font(Fonts.menuItem(k))
            .foregroundStyle(Theme.popupItem)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, s(MenuMetrics.padX))
            .frame(height: s(MenuMetrics.rowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered || isOpen ? Theme.popupRowHover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering

                if hovering {
                    open()
                }
            }
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
    }
}
