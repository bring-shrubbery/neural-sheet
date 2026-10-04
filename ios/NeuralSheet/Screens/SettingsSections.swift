import NeuralSheetCore
import SwiftUI

/// Settings → Sound bank (sub-issue H): what the MIDI and the click play through. iOS has no
/// General MIDI bank, so the row offers GeneralUser GS to download (with its licence), a `.sf2` or
/// `.dls` from Files, or none -- the MIDI synth's fallback tone, labelled as such.
struct SoundBankSection: View {
    @State private var showsImporter = false

    private var library: SoundBankLibrary { .shared }

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: library.currentName ?? String(localized: "None (fallback tone)", comment: "Settings → Sound bank (iOS): no bank, the synth's own tone"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Text("Sound bank", comment: "Settings → Audio: the sound bank row")
            }
            .accessibilityIdentifier("sound-bank")

            generalMidiRow

            Button { showsImporter = true } label: {
                Text("Choose from Files…", comment: "Settings → Sound bank (iOS): pick a .sf2 or .dls from Files")
            }

            if library.current != nil {
                Button(role: .destructive) { library.remove() } label: {
                    Text("Use the Fallback Tone", comment: "Settings → Sound bank (iOS): remove the bank; the synth plays its own tone")
                }
            }

            if let failure = library.failure {
                Text(verbatim: failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sound bank", comment: "Settings → Audio: the sound bank row")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("A SoundFont (.sf2) or DLS (.dls) file the MIDI and the click play through.")
                Text("\(SoundBankManifest.name) by \(SoundBankManifest.author): free to use and redistribute.",
                     comment: "Settings → Sound bank (iOS): the downloadable bank's author and licence in brief")
                Link(destination: SoundBankManifest.licenceURL) {
                    Text("GeneralUser GS licence", comment: "Settings → Sound bank (iOS): a link to the bank's licence text")
                }
            }
            .font(.footnote)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: SoundBankLibrary.contentTypes) { result in
            if case let .success(url) = result {
                library.importBank(from: url, securityScoped: true)
            }
        }
    }

    /// GeneralUser GS: Download, its progress with Cancel, Retry after a failure, or a tick once it
    /// is the bank in use.
    @ViewBuilder
    private var generalMidiRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download GM bank", comment: "Settings → Sound bank (iOS): the General MIDI bank download")
                Text(verbatim: "\(SoundBankManifest.name) \(SoundBankManifest.version) · \(ByteCountFormatter.string(fromByteCount: SoundBankManifest.byteSize, countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if case let .failed(message) = library.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            switch library.phase {
            case let .downloading(received, total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .frame(width: 80)
                Button { library.cancelDownload() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Cancel download", comment: "Settings: stops a model download"))

            case .verifying:
                ProgressView()

            case .idle, .failed:
                if library.hasGeneralMidiBank {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                } else {
                    Button { library.startDownload() } label: {
                        if case .failed = library.phase {
                            Text("Retry", comment: "Settings: starts a failed model download again")
                        } else {
                            Text("Download", comment: "Settings: starts a model download")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("download-gm-bank")
                }
            }
        }
    }
}

/// Settings → Recording: the count-in and the click while recording, as the Mac's Settings →
/// Audio has them.
struct RecordingSection: View {
    private var appSettings: AppSettings { .shared }

    var body: some View {
        @Bindable var appSettings = appSettings

        Section {
            Picker(selection: $appSettings.settings.countInBars) {
                ForEach(GlobalSettings.countInChoices, id: \.self) { bars in
                    Text(verbatim: Self.countInLabel(bars)).tag(bars)
                }
            } label: {
                Text("Count-in", comment: "Settings → Audio: the count-in picker")
            }

            Toggle(isOn: $appSettings.settings.clickWhileRecording) {
                Text("Click while recording", comment: "Settings → Audio: the click during a take")
            }
        } header: {
            Text("Recording", comment: "Settings (iOS): the count-in and the click while recording")
        } footer: {
            Text("The count-in plays a click at the project's tempo and meter, then starts the take on the next downbeat.")
        }
    }

    private static func countInLabel(_ bars: Int) -> String {
        switch bars {
        case 0: String(localized: "Off", comment: "Settings → Audio: no count-in")
        default: String(localized: "\(bars) bars", comment: "Settings → Audio: a count-in of so many bars")
        }
    }
}

/// Settings → After transcription: the filters a run's notes go through as they land, the Mac's
/// Settings → Model section.
struct AfterTranscriptionSection: View {
    private var appSettings: AppSettings { .shared }

    var body: some View {
        @Bindable var appSettings = appSettings

        Section {
            Picker(selection: $appSettings.settings.minimumNoteLength) {
                ForEach(NoteFilter.minimumLengthChoices, id: \.self) { seconds in
                    (seconds == 0 ? Text("Off")
                                  : Text(verbatim: "\(Int((seconds * 1000).rounded())) ms")).tag(seconds)
                }
            } label: {
                Text("Drop notes shorter than")
            }

            Picker(selection: $appSettings.settings.minimumConfidence) {
                ForEach(NoteFilter.minimumConfidenceChoices, id: \.self) { confidence in
                    (confidence == 0 ? Text("Off")
                                     : Text(verbatim: "\(Int((confidence * 100).rounded())) %")).tag(confidence)
                }
            } label: {
                Text("Drop notes less sure than")
            }
        } header: {
            Text("After transcription")
        } footer: {
            Text("Dropped notes are gone; lower the setting and transcribe again to get them back.")
        }
    }
}

/// Settings → About: the version, and the licences of what the app is built from and downloads.
struct AboutSection: View {
    static let noticesURL = URL(string: "https://github.com/bring-shrubbery/neural-sheet/blob/main/THIRD_PARTY_NOTICES.md")!

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: SettingsScreen.version)
            } label: {
                Text("Version", comment: "Settings → About: the app's version")
            }

            Link(destination: Self.noticesURL) {
                Text("Licences", comment: "Settings → About: a link to the third-party notices")
            }

            Link(destination: ModelSettingsLinks.modelLicenceURL) {
                Text("Model weights: CC BY-NC 4.0 (non-commercial)", comment: "Settings → Model: the transcription weights' licence")
            }
        } header: {
            Text("About", comment: "Settings (iOS): the version and the licences")
        }
    }
}

/// Where the transcription weights' licence is, as the Mac's Settings → Model links it.
enum ModelSettingsLinks {
    static let modelLicenceURL = URL(string: "https://huggingface.co/DamRsn/muscriptor-gguf")!
}
