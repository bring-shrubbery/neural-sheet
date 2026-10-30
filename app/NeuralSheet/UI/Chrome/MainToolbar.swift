import AppKit
import NeuralSheetCore
import SwiftUI

/// The window's unified toolbar (native chrome design §2, §4): the tabs as a segmented control
/// beside the title, each tab's actions at the trailing end -- what the Transcribe, Edit and Score
/// toolbar rows carried -- and the inspector's toggle at the end. The system lays the items out
/// in glass and folds what does not fit into its overflow menu.
struct MainToolbar: ToolbarContent {
    let model: AppModel
    @Binding var isInspectorShown: Bool

    var body: some ToolbarContent {
        // Leading, beside the title: with the sidebar and the inspector open the toolbar's middle
        // is not wide enough for the tabs and a tab's actions both.
        ToolbarItem(placement: .navigation) {
            WorkspacePicker(model: model)
        }

        switch model.workspace {
        case .transcribe:
            ToolbarItemGroup(placement: .primaryAction) {
                TranscribeItems(model: model)
            }
        case .edit:
            ToolbarItemGroup(placement: .primaryAction) {
                EditItems(model: model)
            }
        case .score:
            ToolbarItemGroup(placement: .primaryAction) {
                ScoreItems(model: model)
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button { isInspectorShown.toggle() } label: {
                Label {
                    Text(isInspectorShown ? "Hide Inspector" : "Show Inspector")
                } icon: {
                    Image(systemName: "sidebar.trailing")
                }
            }
            .help(Text(isInspectorShown ? "Hide Inspector" : "Show Inspector"))
        }
    }
}

// MARK: - Tabs

/// Transcribe, Edit, Score (⌘1, ⌘2, ⌘3). Edit and Score refuse a switch until there is a
/// finished transcription, as the tab strip's did.
private struct WorkspacePicker: View {
    let model: AppModel

    var body: some View {
        Picker(selection: Binding(get: { model.workspace }, set: { model.setWorkspace($0) })) {
            Text("Transcribe").tag(Workspace.transcribe)
            Text("Edit").tag(Workspace.edit)
            Text("Score").tag(Workspace.score)
        } label: {
            Text("Workspace", comment: "Toolbar: the Transcribe / Edit / Score control, for VoiceOver")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .tooltip(model.canEdit ? "" : String(localized: "Transcribe the audio first"))
    }
}

// MARK: - Transcribe

/// Stems (stem separation design §6), Re-transcribe, and the bin with its two choices.
private struct TranscribeItems: View {
    let model: AppModel

    var body: some View {
        let installed = model.hasStemsModel
        // The bin is live as soon as there is anything to throw away, audio with no transcription
        // included. Not while a run of either kind is in flight: stopping one is its own cancel.
        let canClear = (model.state == .audioLoaded || model.state == .populated) && model.regionJob == nil

        Toggle(isOn: Binding(get: { model.separateStems && installed }, set: { model.separateStems = $0 })) {
            Label {
                Text("Stems")
            } icon: {
                Image(systemName: "square.3.layers.3d")
            }
        }
        .toggleStyle(.button)
        .labelStyle(.titleAndIcon)
        .disabled(!installed)
        .tooltip(installed
            ? "Separate the take into drums, bass, vocals and the rest before transcribing, each with its own instruments"
            : "Download the Stems model in Settings › Model")

        RetranscribeButton(model: model)

        Menu {
            Button(String(localized: "Clear audio and transcription", comment: "The bin's right-click menu"), action: model.clear)

            // Keeps the file loaded and the instrument selection with it, so the obvious next move
            // -- adjust the selection and run again -- does not start with re-dropping the audio.
            Button(String(localized: "Clear transcription only", comment: "The bin's right-click menu"), action: model.clearTranscription)
                .disabled(model.state != .populated)
        } label: {
            Label {
                Text(AccessibilityText.clear)
            } icon: {
                Image(systemName: "trash")
            }
        } primaryAction: {
            model.clear()
        }
        .disabled(!canClear)
        .tooltip("Clear audio and transcription | Shift + Backspace")
    }
}

// MARK: - Edit

/// The tools, snap and its division, Quantize, Re-transcribe and the MIDI chip (design §6.1,
/// editor commands design §2, MIDI out design §2). The grid, the swing and the key are the
/// inspector's; Undo and Redo are the Edit menu's (⌘Z, ⇧⌘Z).
private struct EditItems: View {
    let model: AppModel

    var body: some View {
        let editor = model.editor

        Picker(selection: Binding(get: { editor.tool }, set: { model.setTool($0) })) {
            Label { Text(AccessibilityText.selectTool) } icon: { Image(systemName: "cursorarrow") }
                .tag(EditorState.Tool.select)
            Label { Text(AccessibilityText.drawTool) } icon: { Image(systemName: "pencil") }
                .tag(EditorState.Tool.draw)
            Label { Text(AccessibilityText.eraseTool) } icon: { Image(systemName: "eraser") }
                .tag(EditorState.Tool.erase)
        } label: {
            Text("Tool", comment: "Toolbar: the Select / Draw / Erase control, for VoiceOver")
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .tooltip("Select (V) · Draw (D) · Erase (E)")

        ControlGroup {
            Toggle(isOn: Binding(get: { editor.snapEnabled }, set: { model.setSnapEnabled($0) })) {
                Label {
                    Text(AccessibilityText.snapToGrid)
                } icon: {
                    Icons.MagnetStroked()
                        .stroke(style: Icons.strokeStyle(scale: 1))
                        .frame(width: 14, height: 14)
                }
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .tooltip("Snap to grid")

            Menu {
                ForEach(GridDivision.allCases, id: \.self) { division in
                    Toggle(division.label, isOn: Binding(get: { editor.grid.division == division },
                                                         set: { if $0 { model.setGridDivision(division) } }))
                }
            } label: {
                Text(editor.grid.division.label)
            }
            .tooltip("Grid division")
            .accessibilityLabel(Text(AccessibilityText.gridDivision))
        }

        Button("Quantize", action: model.quantizeSelectionOrAll)
            .tooltip("Quantize selection (⌘U)")

        RetranscribeButton(model: model)

        // The drag-out, at the trailing end (MIDI out design §2).
        MidiDragChip(model: model)
    }
}

// MARK: - Score

/// Continuous / Pages, the page size, Parts, Sheet…, Export PDF and the MIDI chip (arrangement
/// design §6). The grid and the key are the inspector's.
private struct ScoreItems: View {
    let model: AppModel

    @State private var sheetCard = PopupMenuPresenter()
    @State private var sheetAnchor: NSView?

    var body: some View {
        let arrangement = model.arrangement

        Picker(selection: Binding(get: { arrangement.layout }, set: { model.setScoreLayout($0) })) {
            Text(String(localized: "Continuous", comment: "Score toolbar: the systems in one column")).tag(ScoreLayoutMode.continuous)
            Text(String(localized: "Pages", comment: "Score toolbar: the systems on printed pages")).tag(ScoreLayoutMode.pages)
        } label: {
            Text("Layout", comment: "Toolbar: the Continuous / Pages control, for VoiceOver")
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Picker(selection: Binding(get: { arrangement.pageSize }, set: { model.setPageSize($0) })) {
            ForEach(PageSize.allCases, id: \.self) { size in
                Text(verbatim: size.localizedName).tag(size)
            }
        } label: {
            Text("Page size", comment: "Toolbar: the A4 / Letter menu, for VoiceOver")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        // Only pages have a size; the continuous view leaves the room to the rest.
        .opacity(arrangement.layout == .pages ? 1 : 0)
        .disabled(arrangement.layout != .pages)

        // A hidden part loses its name on the page, which is the only way to its card; this menu
        // is how it comes back.
        Menu {
            ForEach(model.mixer.entries, id: \.program) { entry in
                let hidden = model.arrangement.display(for: entry.program).isHidden

                Toggle(entry.info.localizedName, isOn: Binding(get: { !hidden },
                                                               set: { model.setPartHidden(!$0, program: entry.program) }))
            }
        } label: {
            Text("Parts")
        }
        .disabled(model.mixer.entries.isEmpty)
        .tooltip("Show or hide a part")

        Button("Sheet…", action: showSheetCard)
            .background(AnchorCatcher { sheetAnchor = $0 })
            .tooltip("Title, subtitle, composer, arranger, copyright")
            .onDisappear { sheetCard.dismiss() }

        Button(action: model.exportPDF) {
            Label {
                Text("Export PDF")
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(!model.canExport)
        .tooltip("Write the pages as a PDF (⌥⇧⌘P)")

        // The drag-out, at the trailing end (MIDI out design §2).
        MidiDragChip(model: model)
    }

    /// The sheet card under its button, in a menu panel that takes key for its fields.
    private func showSheetCard() {
        guard let anchor = sheetAnchor else { return }

        let card = sheetCard
        let model = model

        card.show(from: anchor, width: SheetCard.width, scale: 1) {
            SheetCard(model: model, host: card)
        }
    }
}
