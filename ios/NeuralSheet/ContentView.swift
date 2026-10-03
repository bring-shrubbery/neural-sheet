import Foundation
import NeuralSheetCore
import NeuralSheetEngine
import SwiftUI

/// The scaffold's only screen: the name, the version and build, and one line read from each
/// linked piece (the engine package, the core package, the demucs bridge), so a build that runs
/// is a build that links.
struct ContentView: View {
    @State private var proof = AudioProof()

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
            Text("NeuralSheet")
                .font(.largeTitle.bold())
            Text(version)
                .foregroundStyle(.secondary)
            Text(linkLine)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            // Temporary audio proof (sub-issue B); goes with the Transcribe screen (D).
            HStack {
                Button("Play test take") { Task { await proof.playTestTake() } }
                Button("Record 3 s") { Task { await proof.record() } }
            }
            .buttonStyle(.bordered)
            .disabled(proof.busy)
            Text(proof.status)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .onAppear {
            print("NeuralSheet: \(version); \(linkLine)")
        }
        .task {
            await proof.runFromLaunchArguments()
        }
    }
}

#Preview {
    ContentView()
}
