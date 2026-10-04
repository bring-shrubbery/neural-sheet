import AppKit
import SwiftUI

/// The container's one window: the version, Open NeuralSheet, and how the plugin gets registered.
struct ContainerView: View {
    /// The Mac app, opened by its bundle identifier wherever it is installed.
    private static let appBundleIdentifier = "com.quassum.neuralsheet"
    private static let website = URL(string: "https://neural-sheet.quassum.com")!

    /// Set when Open NeuralSheet found no app to open.
    @State private var appMissing = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("NeuralSheet Plugin")
                .font(.title.weight(.semibold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)

            Text(
                "The NeuralSheet Audio Unit is registered when this app is run once. Look for “Quassum: NeuralSheet” among your host’s effects."
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open NeuralSheet", action: openApp)
                .keyboardShortcut(.defaultAction)

            if appMissing {
                VStack(spacing: 4) {
                    Text("NeuralSheet is not installed.")
                        .foregroundStyle(.secondary)
                    Link("neural-sheet.quassum.com", destination: Self.website)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) else {
            appMissing = true
            return
        }

        appMissing = false
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
