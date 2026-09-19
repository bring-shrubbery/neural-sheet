import AppKit
import NeuralSheetCore
import SwiftUI

/// One size as the Model tab shows it, read off the `AppModel` once per body so the row's own
/// drawing never touches the model.
nonisolated struct ModelRow: Equatable {
    let size: ModelSize
    var isInstalled: Bool
    var isInUse: Bool
    var phase: DownloadPhase

    /// What an earlier attempt left in the part file; a start from here resumes rather than
    /// downloads. Only meaningful while `phase` is `.idle`.
    var partialBytes: Int64 = 0

    /// `Status::getProgress`, in [0, 1].
    var progress: Double {
        guard case let .downloading(received, total) = phase, total > 0 else { return 0 }

        return min(1, max(0, Double(received) / Double(total)))
    }

    var spec: ModelSpec {
        ModelManifest.spec(for: size)
    }
}

/// Settings → Model (`ModelDownloadPanel`, §3.2): a row per size -- an installed one picked by
/// its radio, a missing one offering its download -- the models folder, and the weights' licence.
///
/// The tab polls nothing itself: `AppModel` re-scans the models folder at 10 Hz and republishes
/// `installedModels` and `downloadPhases`, and the body follows them.
struct ModelSettingsView: View {
    let model: AppModel

    /// Part-file sizes, stat'ed once when the tab opens and again only when a row's own phase
    /// settles (to `.idle` or `.failed`) or the installed set moves. Never in `body`: the
    /// downloading row's phase changes on every chunk, and a stat per chunk per row on the main
    /// actor is what the C++ panel's 10 Hz poll avoided.
    @State private var partialBytes: [ModelSize: Int64] = [:]

    /// Where the weights come from, and what they may be used for.
    static let licenceText = "Model weights: CC BY-NC 4.0 (non-commercial)"
    static let licenceURL = URL(string: "https://huggingface.co/DamRsn/muscriptor-gguf")!

    var body: some View {
        let hasInstalledModel = !model.installedModels.isEmpty

        Form {
            Section {
                ForEach(rows, id: \.size) { row in
                    ModelRowView(row: row,
                                 select: { model.setModelSize(row.size) },
                                 download: { model.startDownload(row.size) },
                                 cancel: { model.cancelDownload(row.size) })
                }
            } header: {
                Text(hasInstalledModel ? "Transcription model" : "No transcription model installed")
            } footer: {
                Text(hasInstalledModel ? "Select the model to transcribe with." : "Download a model to start transcribing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Models folder") {
                    Button("Open in Finder") {
                        model.openModelsFolder()
                    }
                }
            } footer: {
                HStack(spacing: 4) {
                    Text(Self.licenceText)
                    Text("·")
                    Link("Hugging Face", destination: Self.licenceURL)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for size in ModelSize.allCases {
                refreshPartialBytes(for: size)
            }
        }
        .onChange(of: model.downloadPhases) { old, new in
            for size in ModelSize.allCases {
                let phase = new[size] ?? .idle

                guard phase != old[size] ?? .idle else { continue }

                // Only the settled phases show the button that reads the count; a chunk of
                // progress on the downloading row is not a reason to stat the others.
                switch phase {
                case .idle, .failed: refreshPartialBytes(for: size)
                case .downloading, .verifying: break
                }
            }
        }
        .onChange(of: model.installedModels) { _, _ in
            for size in ModelSize.allCases {
                refreshPartialBytes(for: size)
            }
        }
    }

    private var rows: [ModelRow] {
        ModelSize.allCases.map { size in
            let isInstalled = model.installedModels.contains(size)
            let phase = model.downloadPhases[size] ?? .idle

            return ModelRow(size: size,
                            isInstalled: isInstalled,
                            isInUse: model.modelSize == size,
                            phase: phase,
                            partialBytes: !isInstalled && phase == .idle ? partialBytes[size] ?? 0 : 0)
        }
    }

    private func refreshPartialBytes(for size: ModelSize) {
        partialBytes[size] = Self.partialBytes(for: size, in: model.paths)
    }

    /// The part file's size, or 0 without one -- the "Resume" the C++ panel read off
    /// `Status::downloadedBytes` outside a download. `AppModel` publishes no such thing, so it is
    /// read here, off the same path the downloader writes to.
    private static func partialBytes(for size: ModelSize, in paths: AppPaths) -> Int64 {
        let part = paths.models.appendingPathComponent(ModelManifest.spec(for: size).partFileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: part.path)

        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Rows

/// One size: a radio for an installed one, the name and its meta line, and whatever the state
/// calls for on the right -- a download button, its progress and a cancel, or "Verifying".
private struct ModelRowView: View {
    let row: ModelRow
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            radio

            VStack(alignment: .leading, spacing: 2) {
                Text(row.size.displayName)
                    .foregroundStyle(row.isInstalled ? .primary : .secondary)

                Text(meta)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !row.isInstalled {
                controls
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isInstalled, !row.isInUse {
                select()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var radio: some View {
        Image(systemName: row.isInUse ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(row.isInUse ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .opacity(row.isInstalled ? 1 : 0.4)
            .accessibilityLabel(row.isInUse ? "Selected" : row.isInstalled ? "Installed" : "Not installed")
    }

    private var isFailed: Bool {
        if case .failed = row.phase, !row.isInstalled {
            return true
        }

        return false
    }

    private var meta: String {
        let spec = row.spec

        switch row.phase {
        case let .failed(message) where !row.isInstalled:
            return message

        case let .downloading(received, _) where !row.isInstalled:
            return "\(TimeFormat.fileSize(bytes: received)) of \(TimeFormat.fileSize(bytes: spec.byteSize))"

        case .verifying where !row.isInstalled:
            return "\(TimeFormat.fileSize(bytes: spec.byteSize)) of \(TimeFormat.fileSize(bytes: spec.byteSize))"

        default:
            return "\(TimeFormat.fileSize(bytes: spec.byteSize))  \u{00B7}  \(row.size.hint)"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch row.phase {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: row.progress)
                    .frame(width: 90)

                Text("\(Int((100 * row.progress).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)

                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop the download. Starting it again resumes where it stopped")
                .accessibilityLabel("Stop download")
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("Verifying…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .idle, .failed:
            Button(downloadLabel, systemImage: "arrow.down.circle", action: download)
        }
    }

    private var downloadLabel: String {
        if case .failed = row.phase {
            return "Retry"
        }

        return row.partialBytes > 0 ? "Resume" : "Download"
    }
}
