import Foundation
import NeuralSheetCore
import NeuralSheetEngine
import SwiftUI

/// The scaffold's only screen: the name, the version and build, and one line read from each
/// linked piece (the engine package, the core package, the demucs bridge), so a build that runs
/// is a build that links.
struct ContentView: View {
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
        }
        .padding()
        .onAppear {
            print("NeuralSheet: \(version); \(linkLine)")
        }
    }
}

#Preview {
    ContentView()
}
