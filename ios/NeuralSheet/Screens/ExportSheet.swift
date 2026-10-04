import NeuralSheetCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// The export sheet and the Replace / Add question of a dropped MIDI file, once per project's
    /// screens: whichever screen's Export menu or roll started it.
    func exportPresentation(_ model: MobileModel) -> some View {
        modifier(ExportPresentation(model: model))
    }
}

private struct ExportPresentation: ViewModifier {
    let model: MobileModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.exports.isSheetShown },
                                        set: { if !$0 { model.dismissExport() } })) {
                ExportSheet(model: model)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(Text(verbatim: model.exports.pendingMIDI.map {
                                    String(localized: "Import “\($0.fileName)”?", comment: "Alert title: File → Import MIDI… over a transcription")
                                } ?? ""),
                                isPresented: Binding(get: { model.exports.pendingMIDI != nil },
                                                     set: { if !$0 { model.resolveMIDIImport(replacing: nil) } }),
                                titleVisibility: .visible) {
                Button { model.resolveMIDIImport(replacing: true) } label: {
                    Text("Replace the notes", comment: "Alert button: the MIDI file's notes replace the transcription's")
                }
                Button { model.resolveMIDIImport(replacing: false) } label: {
                    Text("Add to the notes", comment: "Alert button: the MIDI file's notes join the transcription's")
                }
                Button(role: .cancel) { model.resolveMIDIImport(replacing: nil) } label: {
                    Text("Cancel", comment: "Alert button")
                }
            } message: {
                Text("The take already has a transcription. The file's notes can replace its notes or be added to them.",
                     comment: "Alert body: File → Import MIDI… over a transcription")
            }
    }
}

/// What an export shows while it asks, works, fails or is ready: the audio choices, a bar with
/// Cancel, the failure, or the files with Share and Save to Files. Closing it cancels whatever
/// is running and removes the files it wrote.
struct ExportSheet: View {
    let model: MobileModel

    var body: some View {
        let exports = model.exports

        NavigationStack {
            Group {
                if let failure = exports.failure {
                    ContentUnavailableView {
                        Label(failure.title, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure.message)
                    }
                } else if let ready = exports.ready {
                    ExportReadyView(model: model, ready: ready)
                } else if let render = exports.audioRender {
                    ExportProgressView(title: Text("Exporting Audio", comment: "File → Export Audio…: the sheet's title while the file is written"), detail: render.fileName, progress: render.progress) {
                        model.cancelAudioExport()
                    }
                } else if let stems = exports.stemsExport {
                    ExportProgressView(title: stems.phase == .separating
                                           ? Text("Separating stems", comment: "Transcribe screen and Live Activity: Demucs is splitting the take")
                                           : Text("Exporting Stems", comment: "Export Stems…: the sheet's title while the files are written"),
                                       detail: model.exportTakeName, progress: Double(stems.progress)) {
                        model.cancelStemsExport()
                    }
                } else if exports.isAskingAudio {
                    AudioExportForm(model: model)
                }
            }
            .toolbar {
                // While working, the bar's own Cancel is the one, as on the Mac's sheet.
                if exports.audioRender == nil, exports.stemsExport == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { model.dismissExport() } label: {
                            if exports.ready != nil || exports.failure != nil {
                                Text("Done", comment: "The export sheet: close it")
                            } else {
                                Text("Cancel", comment: "A dialog's cancel button")
                            }
                        }
                        .accessibilityIdentifier("export-close")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // The document's own Back would otherwise show in the sheet's bar.
            .navigationBarBackButtonHidden()
        }
        .interactiveDismissDisabled(exports.audioRender != nil || exports.stemsExport != nil)
    }
}

/// What is being written, a bar, and Cancel, as the Mac's render sheet.
private struct ExportProgressView: View {
    let title: Text
    let detail: String
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title.font(.headline)

            Text(verbatim: detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .accessibilityIdentifier("export-progress")

            HStack {
                Spacer()
                Button(role: .cancel, action: cancel) {
                    Text("Cancel", comment: "A dialog's cancel button")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export-cancel")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The Mac's accessory as a form: What / Range / Format, the remembered choice, then Export.
private struct AudioExportForm: View {
    let model: MobileModel

    @State private var choice: ExportCommands.AudioChoice

    init(model: MobileModel) {
        self.model = model
        _choice = State(initialValue: model.rememberedAudioChoice.starting(hasRange: model.editor.range != nil,
                                                                             hasNotes: model.canExportAudioMidi))
    }

    var body: some View {
        let hasNotes = model.canExportAudioMidi
        let hasRange = model.editor.range != nil

        Form {
            Picker(selection: $choice.what) {
                ForEach(AudioExportWhat.allCases, id: \.self) { what in
                    Text(what.localizedTitle)
                        .tag(what)
                        .selectionDisabled(what.includesSynth && !hasNotes)
                }
            } label: {
                Text("What:", comment: "Export Audio: the source (the take, the MIDI or both)")
            }

            Picker(selection: $choice.markedRange) {
                Text("Whole take", comment: "Export Audio: the whole take's length").tag(false)
                Text("Marked range", comment: "Export Audio: only the range marked on the ruler").tag(true).selectionDisabled(!hasRange)
            } label: {
                Text("Range:", comment: "Export Audio: how much of the take")
            }

            Picker(selection: $choice.format) {
                ForEach(AudioExportFormat.allCases, id: \.self) { format in
                    Text(format.localizedTitle).tag(format)
                }
            } label: {
                Text("Format:", comment: "Export Audio: the file format")
            }

            Section {
                Text(verbatim: choice.format.fileName(takeName: model.exportTakeName))
                    .foregroundStyle(.secondary)

                Button { model.startAudioExport(choice) } label: {
                    Text("Export", comment: "File → Export Stems…'s folder panel: the button")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("export-audio-start")
            }
        }
        .navigationTitle(Text("Export Audio", comment: "File → Export Audio…'s save panel"))
    }
}

/// The files, then Share (the system's share sheet) and Save to Files (the system's folder
/// picker, a copy under the same names). Done removes them.
private struct ExportReadyView: View {
    let model: MobileModel
    let ready: MobileModel.ExportedFiles

    @State private var savingToFiles = false

    var body: some View {
        List {
            Section {
                ForEach(ready.files, id: \.self) { url in
                    Label {
                        Text(verbatim: url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "doc")
                    }
                    .accessibilityIdentifier("export-file")
                }
            }

            Section {
                ShareLink(items: ready.files) {
                    Label { Text("Share…", comment: "The export sheet: the system's share sheet") } icon: { Image(systemName: "square.and.arrow.up") }
                }
                .accessibilityIdentifier("export-share")

                Button { savingToFiles = true } label: {
                    Label { Text("Save to Files…", comment: "The export sheet: copy the files into a folder") } icon: { Image(systemName: "folder") }
                }
                .accessibilityIdentifier("export-save")
            }
        }
        .sheet(isPresented: $savingToFiles) {
            FilesExporter(urls: ready.files) { saved in
                savingToFiles = false
                if saved { model.dismissExport() }
            }
            .ignoresSafeArea()
        }
    }
}

/// Save to Files: the system's folder picker exporting copies of the files under their own names
/// -- several at once for the stems -- read from disk rather than loaded into memory.
private struct FilesExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let finished: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.finished = finished
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(finished: finished)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var finished: (Bool) -> Void

        init(finished: @escaping (Bool) -> Void) {
            self.finished = finished
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finished(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finished(false)
        }
    }
}
