import NeuralSheetCore
import PhotosUI
import SwiftUI

/// The Transcribe screen (iOS app design §2, sub-issue D): the take's waveform with Record and
/// Import, the model, the instruments and the Stems switch, Transcribe or Cancel, the run's
/// progress with what it is doing, and the note count once it has landed.
struct TranscribeScreen: View {
    @Bindable var model: MobileModel

    @State private var showsFileImporter = false
    @State private var showsPhotosPicker = false
    @State private var pickedVideo: PhotosPickerItem?
    @State private var showsInstruments = false
    @State private var showsSettings = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var library: ModelLibrary { .shared }

    var body: some View {
        Form {
            if let problem = model.loadProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            takeSection
            settingsSection
            runSection
        }
        // Once there is a take to play: the transport, the mix and the strips (sub-issue H).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.canPlay {
                TransportBar(model: model)
            }
        }
        .toolbar {
            // Once there are notes: the exports, as on the Roll and Score screens (sub-issue I).
            if model.document != nil {
                ToolbarItem(placement: .primaryAction) {
                    ExportMenu(model: model)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings", comment: "The gear button: opens the settings"))
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: MobileModel.importableContentTypes) { result in
            if case let .success(url) = result {
                model.importFile(at: url, securityScoped: true)
            }
        }
        .photosPicker(isPresented: $showsPhotosPicker, selection: $pickedVideo, matching: .videos)
        .onChange(of: pickedVideo) { _, item in
            guard let item else { return }

            pickedVideo = nil
            loadPicked(item)
        }
        .sheet(isPresented: $showsInstruments) {
            InstrumentsSheet(model: model)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsScreen()
        }
    }

    // MARK: - The take

    private var takeSection: some View {
        Section {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))

                if case .recording = model.recording {
                    WaveformStrip(peaks: model.recorder.livePeaks, live: true)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let source = model.source {
                    WaveformStrip(peaks: source.peaks)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if case let .countingIn(remaining) = model.recording {
                    Text(remaining, format: .number)
                        .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                } else if model.isImporting {
                    ProgressView()
                } else {
                    Text("Record or import a take", comment: "Transcribe screen: the empty waveform's hint")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 110)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Waveform", comment: "VoiceOver (iOS Transcribe screen): the take's waveform"))
            .accessibilityValue(waveformValue)
            .accessibilityIdentifier("waveform")

            if let line = takeLine {
                Text(line)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Side by side, or one above the other at the accessibility sizes, where a word no
            // longer fits half the width.
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                recordButton

                Menu {
                    Button { showsFileImporter = true } label: {
                        Label { Text("Files…", comment: "Import menu: choose an audio or video file") } icon: { Image(systemName: "folder") }
                    }
                    Button { showsPhotosPicker = true } label: {
                        Label { Text("Photos…", comment: "Import menu: choose a video from Photos") } icon: { Image(systemName: "photo.on.rectangle") }
                    }
                } label: {
                    Label { Text("Import", comment: "Transcribe screen: the import menu") } icon: { Image(systemName: "square.and.arrow.down") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canImport)
                .accessibilityLabel(Text("Import", comment: "Transcribe screen: the import menu"))
                .accessibilityIdentifier("import")
            }
        }
    }

    private var recordButton: some View {
        Button { model.toggleRecord() } label: {
            Group {
                switch model.recording {
                case nil:
                    Label { Text("Record", comment: "Transcribe screen: starts a take") } icon: { Image(systemName: "record.circle") }
                case .countingIn:
                    Label { Text("Cancel", comment: "Transcribe screen: stops the count-in") } icon: { Image(systemName: "xmark.circle") }
                case .recording:
                    Label { Text("Stop", comment: "Transcribe screen: ends the take") } icon: { Image(systemName: "stop.circle.fill") }
                }
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(model.recording == nil && !model.canImport)
        .accessibilityIdentifier("record")
    }

    /// What the waveform shows, for VoiceOver: the count-in's beat, the take in progress, the
    /// import, or the empty hint; the take line under it names a loaded take.
    private var waveformValue: Text {
        switch model.recording {
        case let .countingIn(remaining):
            return Text(verbatim: "\(String(localized: AccessibilityText.recordState(.countingIn))), \(remaining)")
        case .recording:
            return Text(AccessibilityText.recordState(.recording))
        case nil:
            break
        }

        if model.source != nil {
            return Text(verbatim: takeLine ?? "")
        }

        if model.isImporting {
            return Text("Loading", comment: "VoiceOver value (iOS Transcribe screen): a file is being read into the waveform")
        }

        return Text("Record or import a take", comment: "Transcribe screen: the empty waveform's hint")
    }

    /// The take's name and length; the seconds captured while recording.
    private var takeLine: String? {
        if case let .recording(seconds) = model.recording {
            return String(localized: "Recording \(TimeFormat.transport(seconds))", comment: "Transcribe screen: the take in progress and its length")
        }

        guard let source = model.source else { return nil }

        let name = source.droppedFileName
            ?? String(localized: "take.recorded", defaultValue: "Recording", comment: "The name of a take that was recorded rather than imported, a noun: the Transcribe screen's take line and the Live Activity")

        return "\(name) · \(TimeFormat.transport(source.duration))"
    }

    private func loadPicked(_ item: PhotosPickerItem) {
        model.isImporting = true

        Task {
            let movie = try? await item.loadTransferable(type: PickedMovie.self)
            model.isImporting = false

            if let movie {
                model.importPickedMovie(movie)
            } else {
                model.presentLoadFailure()
            }
        }
    }

    // MARK: - Model, instruments, stems

    private var settingsSection: some View {
        Section {
            modelPicker

            Button { showsInstruments = true } label: {
                LabeledContent {
                    Text(InstrumentsSheet.summary(model.selectedGroups))
                } label: {
                    Text("Instruments", comment: "Transcribe screen: the row that opens the instruments sheet")
                        .foregroundStyle(.primary)
                }
            }
            .tint(.primary)
            .disabled(model.isRunning)
            .accessibilityIdentifier("instruments")

            Toggle(isOn: Binding(get: { model.separateStems && library.hasStemsModel },
                                 set: { model.separateStems = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stems", comment: "Transcribe screen: separate drums, bass and vocals before transcribing")

                    if !library.hasStemsModel {
                        Button { showsSettings = true } label: {
                            Text("Download…", comment: "Transcribe screen: opens the settings to download a model")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .disabled(!library.hasStemsModel || model.isRunning)
            .accessibilityRepresentation {
                Toggle(isOn: Binding(get: { model.separateStems && library.hasStemsModel }, set: { model.separateStems = $0 })) {
                    Text("Stems", comment: "Transcribe screen: separate drums, bass and vocals before transcribing")
                }
                .disabled(!library.hasStemsModel || model.isRunning)
            }
            .accessibilityIdentifier("stems")
        } header: {
            Text("Transcription", comment: "Transcribe screen: the section with the model, instruments and Stems")
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(library.installedTranscriptionSizes, id: \.self) { size in
                Button {
                    model.setModelSize(size)
                } label: {
                    if model.modelSize == size {
                        Label(size.localizedName, systemImage: "checkmark")
                    } else {
                        Text(size.localizedName)
                    }
                }
            }

            Divider()

            Button { showsSettings = true } label: {
                Text("Download…", comment: "Transcribe screen: opens the settings to download a model")
            }
        } label: {
            LabeledContent {
                Text(model.modelSize?.localizedName
                     ?? String(localized: "None installed", comment: "Transcribe screen: no transcription model on the device"))
            } label: {
                Text("Model", comment: "Transcribe screen: the transcription model picker")
                    .foregroundStyle(.primary)
            }
        }
        .tint(.primary)
        .disabled(model.isRunning)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Model", comment: "Transcribe screen: the transcription model picker"))
        .accessibilityValue(Text(verbatim: model.modelSize?.localizedName
                                 ?? String(localized: "None installed", comment: "Transcribe screen: no transcription model on the device")))
        .accessibilityIdentifier("model")
    }

    // MARK: - The run

    private var runSection: some View {
        Section {
            if let run = model.run {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(run.progress))
                        .tint(run.paused ? .orange : .accentColor)
                        .accessibilityLabel(Text("Transcription progress", comment: "VoiceOver (iOS Transcribe screen): the run's progress bar"))

                    HStack {
                        Text(model.runStatusText)
                        Spacer()
                        Text(verbatim: "\(RunSupport.percent(run.progress)) %")
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text("\(model.streamedNotes.count) notes so far", comment: "Transcribe screen: notes found while the run streams")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("progress")

                Button(role: .cancel) { model.cancelTranscription() } label: {
                    Text("Cancel", comment: "Transcribe screen: stops the run")
                        .frame(maxWidth: .infinity)
                }
                .disabled(run.cancelLatched)
                .accessibilityIdentifier("cancel")
            } else {
                Button { model.launchTranscription() } label: {
                    Label { Text("Transcribe", comment: "Transcribe screen: runs the model over the take") } icon: { Image(systemName: "waveform.badge.magnifyingglass") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canTranscribe)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .accessibilityIdentifier("transcribe")

                if let notes = model.document?.notes.count {
                    resultLine(notes: notes)
                } else if !model.hasTranscriptionModel {
                    Text("Download a transcription model in Settings to transcribe.", comment: "Transcribe screen: no model installed")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultLine(notes: Int) -> some View {
        HStack {
            Image(systemName: "music.note.list")
            Text("\(notes) notes", comment: "Transcribe screen: how many notes the transcription holds")

            if let seconds = model.lastRunSeconds {
                Spacer()
                Text(verbatim: "\(Formats.number(seconds, decimals: 1)) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("result")
    }
}
