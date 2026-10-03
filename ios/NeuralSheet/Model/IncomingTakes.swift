import Foundation
import Observation

/// Audio or video the share sheet or another app handed over while no project was open (iOS app
/// design §2, Imports). The file is copied out of the system's loan at once; the document
/// browser then offers a new project with it as the take, which `NeuralSheetDocument(importing:)`
/// makes. With a project open, the take goes straight into that project instead
/// (`ContentView`'s `onOpenURL`).
@Observable
final class IncomingTakes {
    static let shared = IncomingTakes()

    /// The latest file handed over, copied into the temporary directory; nil when none waits.
    private(set) var pending: URL?

    /// Copies `url` out of the loan and keeps it for the next new project. A file the loader
    /// does not accept is ignored: the app was not the one to open it.
    func receive(_ url: URL) {
        print("NeuralSheet: handed \(url.lastPathComponent)")
        guard AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased()) else { return }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Incoming-\(UUID().uuidString)", isDirectory: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        let accessing = url.startAccessingSecurityScopedResource()

        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            print("NeuralSheet: could not take in \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }

        discard()
        pending = copy
        print("NeuralSheet: received \(url.lastPathComponent) for a new project")
    }

    /// Hands the waiting file to a new project, which owns it from then on.
    func take() -> URL? {
        defer { pending = nil }
        return pending
    }

    /// Drops the waiting file.
    func discard() {
        guard let pending else { return }

        try? FileManager.default.removeItem(at: pending.deletingLastPathComponent())
        self.pending = nil
    }
}
