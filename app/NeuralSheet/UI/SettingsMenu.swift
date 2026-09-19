import AppKit
import NeuralSheetCore
import SwiftUI

/// The gear's menu (`NeuralNoteMainView::_buildSettingsMenu`, inventory §11.3):
///
/// 1. Reset Zoom
/// 2. Show Tooltips (ticked while on; persisted)
/// 3. MIDI export: too many instruments ▸ Reuse the last channels / Drop the extra instruments
/// 4. Window size ▸ 50 % … 200 %
/// 5. ——
/// 6. Check for updates
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
    private var scale: CGFloat = 1
    private var model: AppModel?
    private var onWindowScale: (Double) -> Void = { _ in }

    /// `TopBar`'s settings button, in authored pixels: 32 wide at the right padding of 14, in the
    /// 30 px control row that sits at y 11.
    static let gearFrame = CGRect(x: 1280 - 14 - 32, y: 11, width: 32, height: 30)

    enum Submenu {
        case midiOverflow
        case windowSize

        /// The row the submenu hangs off, counting from the top of the list.
        var rowIndex: Int {
            switch self {
            case .midiOverflow: 2
            case .windowSize: 3
            }
        }
    }

    private static let mainTitles = [
        "Reset Zoom", "Show Tooltips", "MIDI export: too many instruments", "Window size", "Check for updates",
    ]

    private static let overflowChoices: [(mode: MidiOverflowMode, title: String)] = [
        (.reuseChannels, "Reuse the last channels"),
        (.dropExtraInstruments, "Drop the extra instruments"),
    ]

    private static let scaleTitles = MainWindowController.presetScales.map { "\(Int(($0 * 100).rounded()))%" }

    var isOpen: Bool { menu.panel != nil }

    /// Opens the menu under the gear.
    ///
    /// - Parameters:
    ///   - window: The window the gear is in; the menu is placed from its content frame.
    ///   - scale: The UI scale the window is drawn at.
    ///   - onWindowScale: Settings → Window size: the controller applies the preset, clamped.
    func open(in window: NSWindow, scale: CGFloat, model: AppModel, onWindowScale: @escaping (Double) -> Void) {
        self.window = window
        self.scale = scale
        self.model = model
        self.onWindowScale = onWindowScale
        submenu = nil

        let width = PopupMenuPresenter.width(forTitles: Self.mainTitles, scale: scale)
        let target = window.convertToScreen(Self.windowRect(forAuthored: Self.gearFrame, in: window, scale: scale))

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

        SubmenuRowView(title: Self.mainTitles[3], isOpen: submenu == .windowSize) { [weak self] in
            self?.openSubmenu(.windowSize)
        }

        MenuSeparator()

        MenuRow(title: Self.mainTitles[4]) { [weak self] in
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

        let titles = which == .midiOverflow ? Self.overflowChoices.map(\.title) : Self.scaleTitles
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

        case .windowSize:
            let applied = Double(scale)

            ForEach(Array(MainWindowController.presetScales.enumerated()), id: \.offset) { [weak self] index, preset in
                // What was applied, not what was asked for: a preset the display cannot hold
                // arrives clamped and ends up unticked.
                MenuRow(title: Self.scaleTitles[index], isTicked: abs(applied - preset) < 0.005) {
                    self?.close()
                    self?.onWindowScale(preset)
                }
            }
        }
    }

    // MARK: - Geometry

    /// An authored rectangle in the window's content, in AppKit's bottom-up window coordinates.
    private static func windowRect(forAuthored rect: CGRect, in window: NSWindow, scale: CGFloat) -> CGRect {
        let contentHeight = window.contentView?.bounds.height ?? MainWindowController.canvas.height * scale

        return CGRect(x: rect.minX * scale,
                      y: contentHeight - (rect.minY + rect.height) * scale,
                      width: rect.width * scale,
                      height: rect.height * scale)
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
