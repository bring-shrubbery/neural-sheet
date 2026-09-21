import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit tab's row above the timeline (design §6.1): tools, snap and division, tempo and
/// downbeat, Quantize, Re-transcribe, Undo/Redo, and the Drag MIDI out button the Transcribe row
/// has.
///
/// Same frame as `Toolbar` -- height, side padding, button height, corner -- so the two tabs'
/// rows sit on the same divider and the drag button does not move between them.
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
                    iconButton(isOn: editor.snapEnabled, tooltip: "Snap to grid", action: { model.setSnapEnabled(!editor.snapEnabled) }) {
                        Icons.MagnetStroked()
                    }

                    labelButton(editor.grid.division.label, tooltip: "Grid division") {
                        showDivisionMenu()
                    }
                    .background(AnchorCatcher { divisionAnchor = $0 })
                }

                HStack(spacing: s(6)) {
                    pillLabel("TEMPO")
                    NumberField(value: editor.grid.bpm, range: TempoGrid.minBpm ... TempoGrid.maxBpm, decimals: 0, width: 46) {
                        model.setGridBpm($0)
                    }
                    .tooltip("Project tempo, also the export tempo")

                    pillLabel("BEAT 1 AT")
                    NumberField(value: editor.grid.offsetSeconds, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 62) {
                        model.setGridOffset($0)
                    }
                    .tooltip("Where bar 1 starts, in seconds")

                    iconButton(isOn: false, tooltip: "Set from playhead", action: model.setGridOffsetFromPlayhead) {
                        Icons.PlayheadTargetStroked()
                    }
                }

                labelButton("Quantize", tooltip: "Quantize selection (⌘U)", action: model.quantizeSelectionOrAll)

                RetranscribeButton(model: model)

                Spacer(minLength: 0)

                HStack(spacing: s(4)) {
                    iconButton(isOn: false, isEnabled: model.canUndo, tooltip: model.undoMenuTitle, action: model.undo) {
                        Icons.UndoStroked()
                    }
                    iconButton(isOn: false, isEnabled: model.canRedo, tooltip: model.redoMenuTitle, action: model.redo) {
                        Icons.RedoStroked()
                    }
                }

                MidiDragButton(model: model)
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
            iconButton(isOn: tool == .select, tooltip: "Select (V)", action: { model.setTool(.select) }) { Icons.ArrowStroked() }
            iconButton(isOn: tool == .draw, tooltip: "Draw (D)", action: { model.setTool(.draw) }) { Icons.PencilStroked() }
            iconButton(isOn: tool == .erase, tooltip: "Erase (E)", action: { model.setTool(.erase) }) { Icons.EraserStroked() }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
    }

    /// A square icon button, 4 short of the row's button height so three of them fit inside the
    /// tool tray's padding at the same height as the label buttons beside it.
    private func iconButton<Icon: Shape>(isOn: Bool, isEnabled: Bool = true, tooltip: String, action: @escaping () -> Void,
                                         icon: () -> Icon) -> some View {
        let s = Scaled(k: k)
        let icon = icon()

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            icon.stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))
                .frame(width: s(Metrics.buttonHeight - 4), height: s(Metrics.buttonHeight - 4))
        }
        .tooltip(tooltip)
    }

    private func labelButton(_ title: String, tooltip: String, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.textBright,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Metrics.buttonPadX))
                .frame(height: s(Metrics.buttonHeight))
        }
        .tooltip(tooltip)
    }

    /// The tracked caps label the sidebar's pills use, in front of each field.
    private func pillLabel(_ text: String) -> some View {
        TrackedLabel(string: text, em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                     font: Fonts.pillLabel(k), scale: k)
            .foregroundStyle(Theme.textLabel)
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
