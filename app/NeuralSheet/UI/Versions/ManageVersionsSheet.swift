import NeuralSheetCore
import SwiftUI

/// Edit → Versions → Manage Versions… (versions design §2): the versions in a table, where a
/// name is edited in place and a version deleted. Here rather than in the menu, since a menu item
/// has no hover or right-click actions. The "Transcription" row is the model's own output and is
/// neither renamed nor deleted. On system controls, as the export dialog is.
struct ManageVersionsSheet: View {
    let model: AppModel

    /// The row whose Delete was clicked, while its question is up.
    @State private var pendingDelete: VersionRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Versions")
                .font(.headline)

            Table(model.versionRows) {
                TableColumn("Name") { row in
                    VersionNameField(model: model, row: row)
                }

                TableColumn("Date") { row in
                    Text(row.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Notes") { row in
                    Text(row.noteCount, format: .number)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 60)

                TableColumn(String()) { row in
                    Button("Delete") { pendingDelete = row }
                        .disabled(row.isTranscription)
                }
                .width(70)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()

                Button("Done") { model.closeManageVersions() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    model.deleteVersion(id: pendingDelete.id)
                }
            }
        } message: {
            Text("The version's notes will be lost. This cannot be undone.")
        }
    }
}

/// A version's name, edited in place: committed on Return or when the field lets go, and put
/// back when left blank.
private struct VersionNameField: View {
    let model: AppModel
    let row: VersionRow

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if row.isTranscription {
            Text(row.name)
        } else {
            TextField("Name", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { text = row.name }
                .onChange(of: row.name) { _, name in text = name }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
    }

    private func commit() {
        model.renameVersion(id: row.id, to: text)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = row.name
        }
    }
}
