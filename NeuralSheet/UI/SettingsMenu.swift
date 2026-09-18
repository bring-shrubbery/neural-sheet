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
/// A `MenuPanel` hung under the gear in the root stack, with a submenu panel beside the row whose
/// arrow the pointer is on. Every tick is read off the model as the menu draws, so a state
/// changed elsewhere -- another window, the file -- shows the moment the menu opens; nothing is
/// drawn for an unticked row, because half the rows are actions. Any click on a row closes the
/// menu, as `PopupMenu` did; the scrim and Escape close it without one.
struct SettingsMenuOverlay: View {
    let model: AppModel
    /// Settings → Window size: the controller applies the preset, clamped to the display.
    let onWindowScale: (Double) -> Void
    let onClose: () -> Void

    @Environment(\.uiScale) private var k
    @State private var openSubmenu: Submenu?
    @State private var keyMonitor: Any?

    /// `TopBar`'s settings button, in authored pixels: 32 wide at the right padding of 14, in the
    /// 30 px control row that sits at y 11. The menu hangs from its bottom-left, the way
    /// `showMenuAsync().withTargetComponent` placed it.
    static let gearFrame = CGRect(x: 1280 - 14 - 32, y: 11, width: 32, height: 30)

    /// The margin a menu keeps from the edge it would otherwise run past.
    private static let edgeMargin: CGFloat = 6

    enum Submenu {
        case midiOverflow
        case windowSize
    }

    private static let mainTitles = [
        "Reset Zoom", "Show Tooltips", "MIDI export: too many instruments", "Window size", "Check for updates",
    ]

    private static let overflowChoices: [(mode: MidiOverflowMode, title: String)] = [
        (.reuseChannels, "Reuse the last channels"),
        (.dropExtraInstruments, "Drop the extra instruments"),
    ]

    private static let scaleTitles = MainWindowController.presetScales.map { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        let s = Scaled(k: k)
        let mainWidth = PopupMenuPresenter.width(forTitles: Self.mainTitles, scale: 1)
        let mainX = min(Self.gearFrame.minX, MainWindowController.canvas.width - Self.edgeMargin - mainWidth)
        let mainY = Self.gearFrame.maxY

        ZStack(alignment: .topLeading) {
            // The scrim: nothing to see, everything to click.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            MenuPanel(width: s(mainWidth)) {
                MenuRow(title: Self.mainTitles[0]) {
                    onClose()
                    model.resetZoom()
                }
                .onHover(perform: hoverMainRow)

                MenuRow(title: Self.mainTitles[1], isTicked: model.settings.tooltipsVisible) {
                    onClose()
                    model.settings.tooltipsVisible.toggle()
                }
                .onHover(perform: hoverMainRow)

                SubmenuRow(title: Self.mainTitles[2], isOpen: openSubmenu == .midiOverflow) {
                    openSubmenu = .midiOverflow
                }

                SubmenuRow(title: Self.mainTitles[3], isOpen: openSubmenu == .windowSize) {
                    openSubmenu = .windowSize
                }

                MenuSeparator()

                MenuRow(title: Self.mainTitles[4]) {
                    onClose()
                    model.checkForUpdates(explicit: true)
                }
                .onHover(perform: hoverMainRow)
            }
            .padding(.leading, s(mainX))
            .padding(.top, s(mainY))

            if let openSubmenu {
                submenu(openSubmenu, mainX: mainX, mainY: mainY, mainWidth: mainWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    /// Entering a plain row closes whichever submenu was open.
    private func hoverMainRow(_ hovering: Bool) {
        if hovering {
            openSubmenu = nil
        }
    }

    // MARK: - Submenus

    /// Beside the parent row, top-aligned with it: to the right of the menu when there is room,
    /// else to the left, which is where a menu at the window's right edge always puts it.
    private func submenu(_ which: Submenu, mainX: CGFloat, mainY: CGFloat, mainWidth: CGFloat) -> some View {
        let s = Scaled(k: k)
        let titles = which == .midiOverflow ? Self.overflowChoices.map(\.title) : Self.scaleTitles
        let width = PopupMenuPresenter.width(forTitles: titles, scale: 1)
        let rowIndex: CGFloat = which == .midiOverflow ? 2 : 3
        let rowTop = mainY + MenuMetrics.listPadY + rowIndex * MenuMetrics.rowHeight
        let fitsRight = mainX + mainWidth + width + Self.edgeMargin <= MainWindowController.canvas.width
        let x = fitsRight ? mainX + mainWidth : mainX - width
        let y = rowTop - MenuMetrics.listPadY

        return MenuPanel(width: s(width)) {
            switch which {
            case .midiOverflow:
                ForEach(Self.overflowChoices, id: \.mode) { choice in
                    MenuRow(title: choice.title, isTicked: model.settings.midiOverflowMode == choice.mode) {
                        onClose()
                        model.settings.midiOverflowMode = choice.mode
                    }
                }

            case .windowSize:
                ForEach(Array(MainWindowController.presetScales.enumerated()), id: \.offset) { index, preset in
                    // What was applied, not what was asked for: a preset the display cannot
                    // hold arrives clamped and ends up unticked.
                    MenuRow(title: Self.scaleTitles[index], isTicked: abs(Double(k) - preset) < 0.005) {
                        onClose()
                        onWindowScale(preset)
                    }
                }
            }
        }
        .padding(.leading, s(x))
        .padding(.top, s(y))
    }

    // MARK: - Escape

    /// A local monitor rather than focus, as the instrument picker has it: the menu is on screen
    /// only while it is open, and Escape has to reach it whatever else has the keyboard.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }

            onClose()
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

/// A row that opens a submenu: the title, and an arrow where a tick would be. Highlighted while
/// the pointer is on it and for as long as its submenu is open, so the pointer can leave for the
/// submenu without the row going dark.
private struct SubmenuRow: View {
    let title: String
    let isOpen: Bool
    let open: () -> Void

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    /// The arrow's box, drawn in the tick column at the tick's size.
    private static let arrowWidth: CGFloat = 5
    private static let arrowHeight: CGFloat = 9

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: 0) {
            Text(title)
                .font(Fonts.menuItem(k))
                .foregroundStyle(Theme.popupItem)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: s(MenuMetrics.padX))

            SubmenuArrow()
                .stroke(Theme.popupItem, style: Icons.strokeStyle(scale: k))
                .frame(width: s(Self.arrowWidth), height: s(Self.arrowHeight))
                .frame(width: s(MenuMetrics.checkboxSize), height: s(MenuMetrics.checkboxSize))
        }
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

/// A chevron pointing right, in its frame.
private nonisolated struct SubmenuArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

        return path
    }
}
