import AppKit
import Foundation
import NeuralSheetCore
import os

/// Where *Open in NeuralSheet* is, for the view.
enum HandoffPhase: Equatable {
    case idle
    /// The package is being written.
    case writing
    /// The app was asked to open it.
    case opened
    /// No app handles `neuralsheet:` URLs: NeuralSheet is not installed, or is older than the
    /// plugin.
    case appMissing
    case failed(String)
}

/// *Open in NeuralSheet* (Audio Unit design §2): the take, the notes, the instruments and the
/// strips as a project package in the App Group container's handoff folder, and the app asked to
/// open it through `neuralsheet://open?path=…` (``HandoffURL``). Main actor.
extension PluginViewModel {
    /// The website the container app points to when NeuralSheet is not installed.
    static let website = URL(string: "https://neural-sheet.quassum.com")!

    /// A take, nothing under way, and not already writing.
    var canOpenInNeuralSheet: Bool {
        guard let capture, capture.phase == .idle, capture.take != nil else { return false }

        return !transcription.isRunning && handoff != .writing
    }

    func openInNeuralSheet() {
        guard canOpenInNeuralSheet, let take = capture?.take else { return }

        // Any URL of the scheme: whether an installed NeuralSheet registers it.
        guard let probe = URL(string: "\(HandoffURL.scheme)://\(HandoffURL.openHost)"),
            NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
        else {
            handoff = .appMissing
            return
        }

        guard let folder = paths.handoff else {
            handoff = .failed("The plugin cannot reach NeuralSheet's shared folder.")
            return
        }

        let session = savedSession()
        let state = HandoffWriter.projectState(selectedGroups: session.selectedGroups, mixer: session.mixer)
        let name = HandoffWriter.packageName(trackName: trackName)

        handoff = .writing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try HandoffWriter.write(take: take, transcription: session.transcription, state: state, name: name,
                                        handoff: folder)
            }

            DispatchQueue.main.async {
                self?.finishHandoff(result)
            }
        }
    }

    /// The package is written: the app is asked to open it, from the extension's own process
    /// (`NSWorkspace` opens URLs from inside the sandbox; an Audio Unit's `extensionContext`
    /// belongs to the host's remote view and is not asked).
    private func finishHandoff(_ result: Result<URL, Error>) {
        switch result {
        case let .success(package):
            guard let url = HandoffURL.url(forPackage: package) else {
                handoff = .failed("The project could not be handed to NeuralSheet.")
                return
            }

            PluginLog.logger.info("handoff: \(package.path, privacy: .public)")
            handoff = .opened

            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let error else { return }

                let message = error.localizedDescription
                PluginLog.logger.error("handoff: open failed: \(message, privacy: .public)")
                DispatchQueue.main.async {
                    self?.handoff = .failed("NeuralSheet could not be opened: \(message)")
                }
            }

        case let .failure(error):
            PluginLog.logger.error("handoff: write failed: \(error.localizedDescription, privacy: .public)")
            handoff = .failed("The project could not be written: \(error.localizedDescription)")
        }
    }
}
