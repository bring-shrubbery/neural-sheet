import Foundation
import NeuralSheetCore
import SwiftUI

/// The document's screens (`ProjectScreens`): Transcribe and the roll (sub-issues D and E); the
/// score and the transport come with sub-issues G and H. Wires what belongs to the document's lifetime: the
/// undo manager iOS autosaves by, a file handed over while the project is open, the scene coming
/// back, and the document closing.
struct ContentView: View {
    @ObservedObject var document: NeuralSheetDocument
    let fileURL: URL?

    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let model = document.model

        ProjectScreens(model: model)
            .onAppear {
                model.undoManager = undoManager
                print("NeuralSheet: \(SettingsScreen.version); showing \"\(title)\"")
            }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.sceneBecameActive() }
            }
            // Audio or video from the share sheet while this project is open: it becomes the
            // take, as a file dropped on the Mac's window does (the old one is an undo away).
            .onOpenURL { url in
                model.importFile(at: url, securityScoped: true)
            }
            .onDisappear { model.closeDocument() }
            .task { await AutoRun.runIfAsked(model) }
    }

    /// The file's name, or "Untitled" before the first save.
    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent
            ?? String(localized: "Untitled", comment: "The title of a project that has not been saved")
    }
}

/// For the simulator and the UI tests: `-autoTranscribe <size>` imports the bundled test take --
/// or the file `-autoTake <path>` names -- into the open project and transcribes it with that
/// model, logging `NeuralSheet run:` lines.
enum AutoRun {
    static func runIfAsked(_ model: MobileModel) async {
        let arguments = ProcessInfo.processInfo.arguments

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }

            return arguments[index + 1]
        }

        guard let size = value(after: "-autoTranscribe").flatMap(ModelSize.init(rawValue:)),
            let take = value(after: "-autoTake").map(URL.init(fileURLWithPath:))
                ?? Bundle.main.url(forResource: "test-take", withExtension: "wav")
        else { return }

        model.setModelSize(size)
        model.importFile(at: take, securityScoped: false)

        while model.isImporting {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard model.modelSize == size else {
            print("NeuralSheet run: the \(size.rawValue) model is not installed in \(AppPaths.standard.models.path)")
            return
        }

        model.launchTranscription()
    }
}
