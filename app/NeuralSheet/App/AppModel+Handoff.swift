import Foundation
import NeuralSheetCore
import os

/// *Open in NeuralSheet* from the Audio Unit (Audio Unit design §2): the plugin writes a package
/// into the App Group container's handoff folder and opens `neuralsheet://open?path=…`. The app
/// checks the path is a handoff (``HandoffURL``), moves the package into `~/Music/NeuralSheet`
/// under a free name, and opens it from there as the Finder's double-click would, the save review
/// included.
extension AppModel {
    private static let handoffLog = Logger(subsystem: "com.quassum.neuralsheet", category: "handoff")

    /// Where the handed-off package is once moved, or nil: a URL that is not a handoff is refused
    /// (and logged), and a move that failed says so when a window can.
    func adoptHandoff(_ url: URL) -> URL? {
        guard let handoff = paths.handoff, let package = HandoffURL.package(from: url, handoff: handoff) else {
            Self.handoffLog.error("refused: \(url.absoluteString, privacy: .public)")
            return nil
        }

        do {
            let adopted = try paths.adoptHandoff(package)
            Self.handoffLog.info("adopted \(package.path, privacy: .public) as \(adopted.path, privacy: .public)")
            return adopted
        } catch {
            Self.handoffLog.error("could not move \(package.path, privacy: .public): \(error.localizedDescription, privacy: .public)")

            if presentError != nil {
                showError(String(localized: "Could not open the project.", comment: "Alert title: File → Open… failed"),
                          AppModel.describe(error))
            }
            return nil
        }
    }
}
