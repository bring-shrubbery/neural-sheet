import NeuralSheetCore
import SwiftUI

/// The settings (iOS app design §2, Screens), reached from the gear on the Transcribe screen and
/// the Settings tab. The models, as the Mac's Settings → Model lists them: each size with its
/// trade-off and download size, downloaded with progress and resumed from where it stopped;
/// tapping an installed size makes it the one runs use. Then (sub-issue H, `SettingsSections`)
/// the sound bank, the count-in and the click while recording, the After transcription filters,
/// and About.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    private var library: ModelLibrary { .shared }
    private var appSettings: AppSettings { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.offeredTranscriptionSizes, id: \.self) { size in
                        ModelRow(size: size, library: library,
                                 isChosen: library.resolvedSize(preferred: appSettings.settings.modelSize) == size) {
                            appSettings.settings.modelSize = size
                        }
                    }
                } header: {
                    Text("Transcription model", comment: "Settings: the section of transcription model sizes")
                } footer: {
                    if !library.offeredTranscriptionSizes.contains(.large) {
                        Text("The Large model needs a device with 8 GB of memory or more.",
                             comment: "Settings: why the Large model is not offered")
                    }
                }

                Section {
                    ModelRow(size: .stems, library: library, isChosen: false, onChoose: nil)
                } header: {
                    Text("Stem separation", comment: "Settings: the section with the Demucs model")
                } footer: {
                    Link(destination: ModelManifest.stemsLicenceURL) {
                        Text("Demucs weights: licence and source", comment: "Settings: a link to the stems model's page")
                    }
                    .font(.footnote)
                }

                SoundBankSection()
                RecordingSection()
                AfterTranscriptionSection()
                AboutSection()
            }
            .navigationTitle(Text("Settings", comment: "The settings screen's title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", comment: "Closes a sheet") }
                }
            }
            .onAppear { library.rescan() }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        return String(localized: "NeuralSheet \(short) (\(build))", comment: "Settings: the app's version and build")
    }
}

/// One model: its name and trade-off, then what can be done with it -- download, follow and
/// cancel the download, retry a failure, or choose and delete it once installed.
private struct ModelRow: View {
    let size: ModelSize
    let library: ModelLibrary
    let isChosen: Bool
    let onChoose: (() -> Void)?

    private var installed: Bool { library.installed.contains(size) }
    private var spec: ModelSpec { library.store.spec(for: size) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(size.localizedName)
                    .font(.body)
                Text("\(size.localizedHint) · \(ByteCountFormatter.string(fromByteCount: spec.byteSize, countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if case let .failed(message) = library.phase(of: size) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            // The name, the trade-off and a failure read as one; tapping it chooses an installed
            // size, so VoiceOver offers it as a button then.
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(installed
                ? (isChosen ? AccessibilityText.modelSelected : AccessibilityText.modelInstalled)
                : AccessibilityText.modelNotInstalled))
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            .accessibilityAddTraits(installed && onChoose != nil ? .isButton : [])
            .accessibilityAction { if installed { onChoose?() } }
            .accessibilityIdentifier("model-\(size.rawValue)")

            Spacer()

            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if installed { onChoose?() }
        }
        .swipeActions {
            if installed {
                Button(role: .destructive) { library.delete(size) } label: {
                    Text("Delete", comment: "Settings: removes a downloaded model")
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch library.phase(of: size) {
        case let .downloading(received, total):
            HStack(spacing: 8) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .frame(width: 80)
                    .accessibilityLabel(Text(AccessibilityText.downloadProgress))
                Button { library.cancelDownload(size) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Cancel download", comment: "Settings: stops a model download"))
            }

        case .verifying:
            HStack(spacing: 6) {
                ProgressView()
                Text("Verifying", comment: "Settings: a downloaded model's checksum is being checked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .idle, .failed:
            if installed {
                if isChosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                } else if onChoose == nil {
                    Text("Installed", comment: "Settings: the model is on the device")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button { library.startDownload(size) } label: {
                    if case .failed = library.phase(of: size) {
                        Text("Retry", comment: "Settings: starts a failed model download again")
                    } else {
                        Text("Download", comment: "Settings: starts a model download")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
