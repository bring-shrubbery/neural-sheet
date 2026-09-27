import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit tab's row above the timeline (design §6.1): tools, snap and division, tempo and
/// downbeat with Tap and Detect (tempo design §5) and the key, Quantize, Re-transcribe, Undo/Redo.
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
            HStack(spacing: s(Metrics.groupGap)) {
                toolSwitcher(editor.tool)

                HStack(spacing: s(4)) {
                    ToolbarControls.iconButton(k: k, isOn: editor.snapEnabled, tooltip: "Snap to grid",
                                               action: { model.setSnapEnabled(!editor.snapEnabled) }) {
                        Icons.MagnetStroked()
                    }

                    ToolbarControls.labelButton(k: k, editor.grid.division.label, tooltip: "Grid division") {
                        showDivisionMenu()
                    }
                    .background(AnchorCatcher { divisionAnchor = $0 })
                }

                GridControls(model: model)

                ToolbarControls.labelButton(k: k, "Quantize", tooltip: "Quantize selection (⌘U)", action: model.quantizeSelectionOrAll)

                RetranscribeButton(model: model)

                Spacer(minLength: 0)

                HStack(spacing: s(4)) {
                    ToolbarControls.iconButton(k: k, isOn: false, isEnabled: model.canUndo, tooltip: model.undoMenuTitle, action: model.undo) {
                        Icons.UndoStroked()
                    }
                    ToolbarControls.iconButton(k: k, isOn: false, isEnabled: model.canRedo, tooltip: model.redoMenuTitle, action: model.redo) {
                        Icons.RedoStroked()
                    }
                }
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
    }

    // MARK: - Pieces

    /// The three tools as a segmented group: one tray, the live tool on the accent fill.
    private func toolSwitcher(_ tool: EditorState.Tool) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(2)) {
            ToolbarControls.iconButton(k: k, isOn: tool == .select, tooltip: "Select (V)", action: { model.setTool(.select) }) { Icons.ArrowStroked() }
            ToolbarControls.iconButton(k: k, isOn: tool == .draw, tooltip: "Draw (D)", action: { model.setTool(.draw) }) { Icons.PencilStroked() }
            ToolbarControls.iconButton(k: k, isOn: tool == .erase, tooltip: "Erase (E)", action: { model.setTool(.erase) }) { Icons.EraserStroked() }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
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
