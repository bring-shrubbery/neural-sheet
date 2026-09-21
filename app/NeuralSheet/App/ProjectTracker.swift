import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// Keeps `AppModel.isProjectEdited` and the window's document state in step with the model
/// (projects design §5.2): re-reads the content snapshot 100 ms after the last change to any of
/// its fields -- a few thousand note structs at most, never per frame -- and pushes the title,
/// the represented file and the dot to the window. One per main view.
@MainActor final class ProjectTracker {
    private let model: AppModel
    private let windowController: MainWindowController
    private var timer: Timer?

    /// Between the last change and the comparison.
    static let debounce: TimeInterval = 0.1

    init(model: AppModel, windowController: MainWindowController) {
        self.model = model
        self.windowController = windowController
    }

    /// Call once, when the view appears.
    func start() {
        observeContent()
        observeDocumentState()
        refresh()
        pushDocumentState()
    }

    // MARK: - Content

    /// Reads every field the snapshot is made of, so the next write to any of them re-arms the
    /// timer; the timer is re-armed only once it has fired, so a fader being dragged compares
    /// ten times a second, not once per pixel.
    private func observeContent() {
        withObservationTracking {
            _ = model.projectContent()
            _ = model.source
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                self.schedule()
                self.observeContent()
            }
        }
    }

    private func schedule() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.refresh()
            }
        }

        // `.common`, so a change made from a menu or during a drag is still noticed.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let edited = model.computeProjectEdited()

        if edited != model.isProjectEdited {
            model.isProjectEdited = edited
        }
    }

    // MARK: - Window

    private func observeDocumentState() {
        withObservationTracking {
            _ = model.projectURL
            _ = model.isProjectEdited
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                self.pushDocumentState()
                self.observeDocumentState()
            }
        }
    }

    private func pushDocumentState() {
        windowController.setDocument(url: model.projectURL, edited: model.isProjectEdited)
    }
}
