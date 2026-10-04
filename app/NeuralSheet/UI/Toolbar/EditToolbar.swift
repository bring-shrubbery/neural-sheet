import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit tab's row above the timeline (design §6.1): tools, snap, division and swing
/// (editor commands design §2), tempo and downbeat with Tap and Detect (tempo design §5) and the
/// key, Quantize, Re-transcribe, Undo/Redo, and the MIDI chip (MIDI out design §2).
///
/// Same frame as `Toolbar` -- height, side padding, button height, corner -- so the two tabs'
/// rows sit on the same divider. The grid and the key are ``GridControls``, shared with the
/// Score toolbar; the buttons are ``ToolbarControls``.
struct EditToolbar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var divisionMenu = PopupMenuPresenter()
    @State private var divisionAnchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let editor = model.editor

        VStack(spacing: 0) {
            // In an `OverflowRow`: the row is the busiest of the three and must never push the
            // sidebar out of a narrow window.
            OverflowRow {
                HStack(spacing: s(Metrics.groupGap)) {
                    toolSwitcher(editor.tool)

                    HStack(spacing: s(4)) {
                        ToolbarControls.iconButton(k: k, isOn: editor.snapEnabled, tooltip: String(localized: "Snap to grid"),
                                                   label: Text(AccessibilityText.snapToGrid),
                                                   action: { model.setSnapEnabled(!editor.snapEnabled) }) {
                            Icons.MagnetStroked()
                        }

                        ToolbarControls.labelButton(k: k, editor.grid.division.label, tooltip: "Grid division",
                                                    label: Text(AccessibilityText.gridDivision)) {
                            showDivisionMenu()
                        }
                        .background(AnchorCatcher { divisionAnchor = $0 })

                        swingField(editor.grid)
                    }

                    GridControls(model: model)

                    ToolbarControls.labelButton(k: k, "Quantize", tooltip: "Quantize selection (⌘U)", action: model.quantizeSelectionOrAll)

                    RetranscribeButton(model: model)

                    Spacer(minLength: 0)

                    HStack(spacing: s(4)) {
                        ToolbarControls.iconButton(k: k, isOn: false, isEnabled: model.canUndo, tooltip: model.undoMenuTitle,
                                                   label: Text(AccessibilityText.undo), action: model.undo) {
                            Icons.UndoStroked()
                        }
                        ToolbarControls.iconButton(k: k, isOn: false, isEnabled: model.canRedo, tooltip: model.redoMenuTitle,
                                                   label: Text(AccessibilityText.redo), action: model.redo) {
                            Icons.RedoStroked()
                        }
                    }

                    // The drag-out, at the trailing end (MIDI out design §2).
                    MidiDragChip(model: model)
                }
                .frame(height: s(Metrics.buttonHeight))
                .padding(.top, s(7))
                .padding(.bottom, s(8))
                .padding(.horizontal, s(Metrics.paddingSide))
            }

            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
        .frame(height: s(Metrics.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgRoot)
        // Switching tabs takes the row away; the menu goes with it, as the Score toolbar's do.
        .onDisappear { divisionMenu.dismiss() }
    }

    // MARK: - Pieces

    /// The three tools as a segmented group: one tray, the live tool on the accent fill.
    private func toolSwitcher(_ tool: EditorState.Tool) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(2)) {
            ToolbarControls.iconButton(k: k, isOn: tool == .select, tooltip: String(localized: "Select (V)"), label: Text(AccessibilityText.selectTool), action: { model.setTool(.select) }) { Icons.ArrowStroked() }
            ToolbarControls.iconButton(k: k, isOn: tool == .draw, tooltip: String(localized: "Draw (D)"), label: Text(AccessibilityText.drawTool), action: { model.setTool(.draw) }) { Icons.PencilStroked() }
            ToolbarControls.iconButton(k: k, isOn: tool == .erase, tooltip: String(localized: "Erase (E)"), label: Text(AccessibilityText.eraseTool), action: { model.setTool(.erase) }) { Icons.EraserStroked() }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
    }

    /// SWING (editor commands design §2): 50…75 %, 50 straight, beside the division it swings
    /// rather than among the grid controls, which the Score toolbar shares and the score ignores
    /// swing. Double-clicking the label puts it back to straight; off for a division that does
    /// not swing.
    private func swingField(_ grid: TempoGrid) -> some View {
        let s = Scaled(k: k)
        let swings = TempoGrid.divisionSwings(grid.division)

        return HStack(spacing: s(6)) {
            ToolbarControls.pillLabel(k: k, "SWING")
                .onTapGesture(count: 2) { model.setSwing(TempoGrid.straightSwing) }

            HStack(spacing: s(3)) {
                NumberField(value: (grid.swing * 100).rounded(), range: 50 ... 75, decimals: 0, width: 34) {
                    model.setSwing($0 / 100)
                }
                .accessibilityLabel(Text(AccessibilityText.swing))

                ToolbarControls.pillLabel(k: k, "%" as String)
            }
            .disabled(!swings)
        }
        .padding(.leading, s(2))
        .opacity(swings ? 1 : Theme.disabledAlpha)
        .tooltip("Swing: how late the second of each pair of eighths or sixteenths falls; 50 % is straight")
    }

    /// The division menu under its button: every `GridDivision`, the current one ticked.
    private func showDivisionMenu() {
        guard let anchor = divisionAnchor else { return }

        let menu = divisionMenu
        let model = model
        let titles = GridDivision.allCases.map(\.label)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(GridDivision.allCases, id: \.self) { division in
                MenuRow(title: division.label, isTicked: model.editor.grid.division == division) {
                    menu.dismiss()
                    model.setGridDivision(division)
                }
            }
        }
    }
}
