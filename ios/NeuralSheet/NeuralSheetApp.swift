import NeuralSheetCore
import SwiftUI

/// The iOS app (iOS app design §2): a document app over `.neuralsheet` packages. The system's
/// document browser opens, creates and lists them, in the app's own folder, Files and iCloud Drive.
/// Its launch screen also offers a new project from a file the share sheet handed over.
@main
struct NeuralSheetApp: App {
    init() {
        // A take lives in the recordings only until its project saves it into the package, so
        // anything there at launch is left over, as on the Mac.
        AppPaths.standard.sweepRecordings()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { NeuralSheetDocument() }) { configuration in
            ContentView(document: configuration.document, fileURL: configuration.fileURL)
        }

        DocumentGroupLaunchScene(Text(verbatim: "NeuralSheet")) {
            NewDocumentButton(Text("Create Project", comment: "Document browser: a new, empty project"))

            IncomingTakeButton()
        } background: {
            Color.accentColor.opacity(0.15)
                .ignoresSafeArea()
                .onOpenURL { url in IncomingTakes.shared.receive(url) }
        }
    }
}

/// The launch screen's offer of a new project from the file the share sheet handed over: a view
/// of its own, so it appears as soon as the file arrives (a scene's body is not observed).
private struct IncomingTakeButton: View {
    private var incoming: IncomingTakes { .shared }

    var body: some View {
        if let pending = incoming.pending {
            NewDocumentButton(Text("New Project from \(pending.deletingPathExtension().lastPathComponent)",
                                   comment: "Document browser: a new project whose take is the file the share sheet handed over"),
                              for: NeuralSheetDocument.self) {
                await MainActor.run { IncomingTakes.shared.take().map(NeuralSheetDocument.init(importing:)) }
            }
        }
    }
}
