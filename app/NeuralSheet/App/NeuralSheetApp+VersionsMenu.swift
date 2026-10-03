import NeuralSheetCore
import SwiftUI

/// Edit → Versions ▸ (versions design §2), out of `NeuralSheetApp+EditMenu.swift` to keep that
/// file focused. Everything it reads — the versions, the comparison, the tab, the document —
/// changes on an edit or a choice, never with the transport, so playback does not rebuild it.
extension NeuralSheetApp {
    @ViewBuilder
    func versionsMenu(model: AppModel) -> some View {
        let rows = model.versionRows

        Menu("Versions") {
            // ⌥⌘S: beside Save (⌘S) and Save As (⇧⌘S), and free.
            Button("Save Version…") { model.saveVersionFromPrompt() }
                .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            // Choosing one restores it as one undoable edit.
            ForEach(rows) { row in
                Button(row.menuTitle) { model.restoreVersion(id: row.id) }
                    .disabled(!model.canRestoreVersion)
            }

            Divider()

            Menu("Compare With") {
                Toggle("None", isOn: Binding(get: { model.comparedVersion == nil },
                                             set: { if $0 { model.compare(with: nil) } }))

                Divider()

                ForEach(rows) { row in
                    Toggle(row.name, isOn: Binding(get: { model.comparedVersion?.id == row.id },
                                                   set: { model.compare(with: $0 ? row.id : nil) }))
                }
            }

            Button("Show Differences") { model.showDifferences() }
                .disabled(!model.canShowDifferences)

            Divider()

            Button("Manage Versions…") { model.openManageVersions() }
        }
        .disabled(!model.canUseVersions)
    }
}
