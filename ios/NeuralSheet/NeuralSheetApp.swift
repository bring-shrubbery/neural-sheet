import SwiftUI

/// The iOS app (iOS app design §2): a document app over `.neuralsheet` packages. The system's
/// document browser opens, creates and lists them, in the app's own folder, Files and iCloud Drive.
@main
struct NeuralSheetApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { NeuralSheetDocument() }) { configuration in
            ContentView(document: configuration.document, fileURL: configuration.fileURL)
        }
    }
}
