import AppKit
import NeuralSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// File → Batch Transcribe… (issue #24 §2, batch and CLI design §2): drop files or folders, choose
/// the model, the instruments, Stems, the outputs, Detect and where they go, then Start. A standard
/// window like Settings rather than the main window's own skin: it is a utility beside it.
struct BatchWindow: View {
    let model: AppModel

    @State private var batch = BatchController()
    @State private var selection = Set<BatchItem.ID>()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            fileTable

            Divider()

            BatchSettingsForm(batch: batch, model: model)

            Divider()

            footer
                .padding(12)
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear {
            if batch.model == nil {
                batch.model = model.modelSize
                batch.stems = model.separateStems && model.hasStemsModel
            }
        }
        // Closing the window mid-batch finishes the file in hand and stops.
        .onDisappear { batch.cancel() }
    }

    // MARK: - Files

    private var fileTable: some View {
        Table(batch.items, selection: $selection) {
            TableColumn("File") { item in
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Status") { item in
                BatchStatusCell(state: item.state)
            }
            .width(min: 180, ideal: 300)
        }
        .overlay {
            if batch.items.isEmpty {
                Text("Drop audio files or folders here")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            batch.add(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onDeleteCommand {
            batch.remove(selection)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Add Files…", action: chooseFiles)

            Button("Remove") { batch.remove(selection) }
                .disabled(selection.isEmpty)

            if let error = batch.setupError {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if batch.isRunning {
                Button("Cancel") { batch.cancel() }
                    .disabled(batch.cancelRequested)
                    .help("Stops after the file being transcribed.")
            } else if batch.hasResults {
                Button("Done") { batch.revealResults() }
                    .help("Shows the files written.")
            }

            Button("Start") { batch.start(settings: model.settings) }
                .keyboardShortcut(.defaultAction)
                .disabled(!batch.canStart)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Files", comment: "Batch window: the open panel's title")
        panel.message = String(localized: "Choose audio files or folders to transcribe", comment: "Batch window: the open panel's message")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AudioFileLoader.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
            + [.folder]

        guard panel.runModal() == .OK else { return }

        batch.add(panel.urls)
    }
}

/// The batch's settings, under the list.
private struct BatchSettingsForm: View {
    @Bindable var batch: BatchController
    let model: AppModel

    var body: some View {
        Form {
            Picker("Model", selection: $batch.model) {
                if batch.model == nil {
                    Text("None installed").tag(ModelSize?.none)
                }

                ForEach(ModelSize.transcription.filter(model.installedModels.contains), id: \.self) { size in
                    Text(size.localizedName).tag(ModelSize?.some(size))
                }
            }

            LabeledContent("Instruments") {
                BatchInstrumentsMenu(selection: $batch.instruments)
            }

            Toggle("Stems", isOn: $batch.stems)
                .disabled(!model.hasStemsModel)
                .help(model.hasStemsModel ? "Separate drums, bass and vocals first."
                                          : "Download the Stems model in Settings → Model.")

            LabeledContent("Outputs") {
                HStack {
                    outputToggle("MIDI", .midi)
                    outputToggle("MusicXML", .musicXML)
                    outputToggle("Project", .project)
                }
            }

            Toggle("Detect tempo and key", isOn: $batch.detect)

            LabeledContent("Output folder") {
                HStack {
                    (batch.outDirectory.map { Text(verbatim: $0.path) } ?? Text("Next to each file"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(batch.outDirectory == nil ? .secondary : .primary)

                    if batch.outDirectory != nil {
                        Button("Reset") { batch.outDirectory = nil }
                    }

                    Button("Choose…", action: chooseFolder)
                }
            }

            Toggle("Replace existing", isOn: $batch.replace)
        }
        .formStyle(.grouped)
        .disabled(batch.isRunning)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// At least one output stays on: the last one cannot be turned off.
    private func outputToggle(_ title: LocalizedStringKey, _ output: TranscriptionOutput) -> some View {
        Toggle(title, isOn: Binding(get: { batch.outputs.contains(output) }, set: { on in
            if on {
                batch.outputs.insert(output)
            } else if batch.outputs.count > 1 {
                batch.outputs.remove(output)
            }
        }))
        .toggleStyle(.checkbox)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Output Folder", comment: "Batch window: the folder panel's title")
        panel.message = String(localized: "Choose where the files are written", comment: "Batch window: the folder panel's message")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        batch.outDirectory = url
    }
}

/// The sidebar picker's choices as a menu: Automatic, then every instrument the model names,
/// ticked where chosen. Each pick adds or removes one, as a tick in the sidebar's panel does.
private struct BatchInstrumentsMenu: View {
    @Binding var selection: [InstrumentGroup]

    var body: some View {
        Menu(title) {
            Toggle(String(localized: RetranscribeButton.automatic), isOn: Binding(get: { selection.isEmpty }, set: { on in
                if on { selection = [] }
            }))

            Divider()

            ForEach(Instruments.all, id: \.program) { info in
                if let group = info.group {
                    Toggle(info.localizedName, isOn: Binding(get: { selection.contains(group) }, set: { on in
                        let chosen = on ? Set(selection).union([group]) : Set(selection).subtracting([group])
                        selection = InstrumentGroup.allCases.filter(chosen.contains)
                    }))
                }
            }
        }
        .fixedSize()
    }

    private var title: String {
        switch selection.count {
        case 0: String(localized: "Automatic", comment: "Batch window: the instruments menu with nothing chosen, the model picks")
        case 1: Instruments.info(forProgram: Instruments.program(for: selection[0])).localizedName
        default: String(localized: "\(selection.count) instruments", comment: "Batch window: the instruments menu, how many are chosen")
        }
    }
}
