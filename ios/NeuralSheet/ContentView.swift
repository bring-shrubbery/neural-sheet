import Foundation
import NeuralSheetCore
import NeuralSheetEngine
import SwiftUI

/// The document's only screen for now (sub-issue C): the project's title and what it holds --
/// the take's length, the notes, the tempo and the key -- with the version and link line from the
/// scaffold and the temporary audio proof (B) playing the document's own take. The screens come
/// with sub-issues D to H.
struct ContentView: View {
    @ObservedObject var document: NeuralSheetDocument
    let fileURL: URL?

    var body: some View {
        DocumentSummary(model: document.model, title: title)
    }

    /// The file's name, or "Untitled" before the first save.
    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent
            ?? String(localized: "Untitled", comment: "The title of a project that has not been saved")
    }
}

private struct DocumentSummary: View {
    let model: MobileModel
    let title: String
    @State private var proof: AudioProof

    init(model: MobileModel, title: String) {
        self.model = model
        self.title = title
        _proof = State(initialValue: AudioProof(model: model))
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private var linkLine: String {
        let stems = String(cString: nsheet_stems_describe_error(Int32(NSHEET_STEMS_OK.rawValue)))
        return "Engine \(Transcriber.sampleRate) Hz · Core \(Int(TempoGrid.defaultBpm)) BPM · Stems \(stems)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Audio").foregroundStyle(.secondary)
                    Text(model.source == nil ? TimeFormat.transportPlaceholder : TimeFormat.transport(model.duration))
                }
                GridRow {
                    Text("Notes").foregroundStyle(.secondary)
                    Text("\(model.document?.notes.count ?? 0)")
                }
                GridRow {
                    Text("Tempo").foregroundStyle(.secondary)
                    Text("\(model.exportTempo, specifier: "%.1f") BPM")
                }
                GridRow {
                    Text("Key").foregroundStyle(.secondary)
                    Text(model.editor.key?.name ?? "None")
                }
            }
            .font(.body.monospacedDigit())

            if let problem = model.loadProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Temporary audio proof (sub-issue B); goes with the Transcribe screen (D).
            HStack {
                Button("Play take") { Task { await proof.playTake() } }
                Button("Record 3 s") { Task { await proof.record() } }
            }
            .buttonStyle(.bordered)
            .disabled(proof.busy)
            Text(proof.status)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(version)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(linkLine)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            print("NeuralSheet: \(version); \(linkLine); showing \"\(title)\"")
        }
        .task {
            await proof.runFromLaunchArguments()
        }
    }
}
