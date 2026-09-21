import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// The recent projects (projects design §5.7, §6): the system's recent-documents list -- which
/// needs no `NSDocument`, survives relaunches and feeds the Dock menu -- filtered through the
/// paths the user removed from it. Re-read when the menu bar starts being tracked and whenever
/// the welcome window asks.
@MainActor @Observable final class RecentProjects {
    private let model: AppModel
    private(set) var urls: [URL] = []

    @ObservationIgnored private var observer: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        refresh()

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        let hidden = Set(model.settings.hiddenRecentProjects)
        let fresh = NSDocumentController.shared.recentDocumentURLs.filter { !hidden.contains($0.path) }

        if fresh != urls {
            urls = fresh
        }
    }

    /// Remove from Recents: hidden, not forgotten by the system.
    func remove(_ url: URL) {
        if !model.settings.hiddenRecentProjects.contains(url.path) {
            model.settings.hiddenRecentProjects.append(url.path)
        }

        refresh()
    }

    /// Clear Menu: the system's list and the hidden set both.
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        model.settings.hiddenRecentProjects = []
        refresh()
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
