import NeuralSheetCore
import SwiftUI

/// The roll screen (iOS app design §2, sub-issues E, F and H): the touch timeline under the
/// transport bar, with the commands menu at its end; under the roll the status line and the bottom bar with the tools, Undo,
/// Redo, the note card and Delete. The card is a sheet on iPhone and a popover on the note on
/// iPad.
struct RollScreen: View {
    let model: MobileModel

    /// Where the card points from while it is up: the long-pressed note's rect in the timeline's
    /// coordinates, or nil for the bar's button, which points from the timeline's bottom edge.
    @State private var isCardShown = false
    @State private var cardAnchor: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model) {
                RollCommandsMenu(model: model)
            }

            TimelineView(model: model) { rect in
                cardAnchor = rect
                isCardShown = true
            }
                .overlay {
                    if model.source == nil {
                        ContentUnavailableView {
                            Label {
                                Text("No take yet", comment: "Roll screen: there is no audio in the project")
                            } icon: {
                                Image(systemName: "pianokeys")
                            }
                        } description: {
                            Text("Record or import a take on the Transcribe screen.",
                                 comment: "Roll screen: where a take comes from")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .popover(isPresented: $isCardShown,
                         attachmentAnchor: cardAnchor.map { .rect(.rect($0)) } ?? .point(.bottom)) {
                    NoteCard(model: model)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                }
                .accessibilityIdentifier("timeline")

            if let status = model.statusLine {
                Text(verbatim: status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(cgColor: TimelinePalette.textPrimary).opacity(0.7))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("status")
            }

            EditBar(model: model) {
                cardAnchor = nil
                isCardShown = true
            }
        }
        .background(Color(cgColor: TimelinePalette.bgRoot))
    }
}

/// The bottom bar: Select / Draw (the Mac's toolbar tools; Erase is the card's and the bar's
/// Delete on touch), Snap, Undo and Redo named after the edit, the note card, Delete.
private struct EditBar: View {
    let model: MobileModel
    let openCard: () -> Void

    var body: some View {
        let selection = model.editor.selection

        HStack(spacing: 4) {
            Picker(selection: Binding(get: { model.editor.tool == .draw ? EditorState.Tool.draw : .select },
                                      set: { model.setTool($0) })) {
                Label { Text("Select", comment: "Roll tools: the Select tool") } icon: { Image(systemName: "cursorarrow") }
                    .tag(EditorState.Tool.select)
                Label { Text("Draw", comment: "Roll tools: the Draw tool") } icon: { Image(systemName: "pencil") }
                    .tag(EditorState.Tool.draw)
            } label: {
                Text("Tool", comment: "Roll tools: the tool picker")
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .frame(width: 96)
            .accessibilityIdentifier("tool")

            Toggle(isOn: Binding(get: { model.editor.snapEnabled }, set: { model.setSnapEnabled($0) })) {
                Image(systemName: "squareshape.split.3x3")
                    .accessibilityLabel(Text("Snap", comment: "Roll tools: snap to the grid"))
            }
            .toggleStyle(.button)
            .frame(minWidth: 44, minHeight: 44)

            Spacer(minLength: 4)

            barButton("arrow.uturn.backward", id: "undo",
                      label: model.undoTitle.map { String(localized: "Undo \($0)", comment: "Edit menu: undo the named edit, e.g. \"Undo Move Note\"") }
                          ?? String(localized: "Undo", comment: "Edit menu: undo with nothing to undo"),
                      enabled: model.canUndo) { model.undo() }

            barButton("arrow.uturn.forward", id: "redo",
                      label: model.redoTitle.map { String(localized: "Redo \($0)", comment: "Edit menu: redo the named edit, e.g. \"Redo Move Note\"") }
                          ?? String(localized: "Redo", comment: "Edit menu: redo with nothing to redo"),
                      enabled: model.canRedo) { model.redo() }

            barButton("slider.horizontal.3", id: "card",
                      label: String(localized: "Note Card", comment: "Roll tools: open the selection's fields"),
                      enabled: model.canEdit && !selection.isEmpty, action: openCard)

            barButton("trash", id: "delete",
                      label: String(localized: "Delete", comment: "Roll tools: delete the selected notes"),
                      enabled: model.canEdit && !selection.isEmpty) { model.deleteSelection() }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(.bar)
    }

    private func barButton(_ systemImage: String, id: String, label: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(id)
    }
}
