import Foundation
import NeuralSheetCore

/// A video's audio (input formats design §3): extracted to a file in the recordings folder and
/// decoded off the main actor, then installed as the take under the video's name. The project is
/// already cleared when this starts; ``importJob`` holds every other way in shut until it lands.
extension AppModel {
    /// Starts the extraction. The task touches nothing of the model's until it hops back, and a
    /// clear cancels it (``clearNow()``), so whatever it finds when it lands is still the empty
    /// project it left.
    ///
    /// Each import writes into a folder of its own inside the recordings, so the file keeps the
    /// video's name (it is what Save names the package's copy) without a cancelled import of a
    /// clip and a fresh drop of the same clip ever writing, or removing, the same path.
    func importVideo(url: URL) {
        let deviceRate = engine.sampleRate
        let folder = paths.recordings.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let displayName = url.deletingPathExtension().lastPathComponent

        importJob = Task.detached { [weak self] in
            let result: Result<(audio: SourceAudio, file: URL), any Error>

            do {
                let file = try await VideoAudioExtractor.extract(video: url, into: folder)
                try Task.checkCancellation()

                let audio = try AudioFileLoader.load(url: file, deviceRate: deviceRate, displayName: displayName)
                result = .success((audio, file))
            } catch {
                result = .failure(error)
            }

            await self?.finishImport(result, folder: folder)
        }
    }

    /// Main actor, still inside the import's task, so `Task.isCancelled` is the import's own: a
    /// clear or a close has been and gone, and there is nothing to install and nothing to say.
    /// Cancellation and this check both run on the main actor, so no clear can fall between them.
    private func finishImport(_ result: Result<(audio: SourceAudio, file: URL), any Error>, folder: URL) {
        guard !Task.isCancelled else {
            removeImportFolder(folder)
            return
        }

        importJob = nil

        switch result {
        case let .success((audio, file)):
            importedAudioURL = file
            installSource(audio)

        case .failure:
            removeImportFolder(folder)
            presentLoadFailure()
        }
    }

    /// Removes one import's folder, and only ever a folder directly inside the recordings, so a
    /// path that came from anywhere else is never touched.
    func removeImportFolder(_ folder: URL) {
        let parent = folder.deletingLastPathComponent().standardizedFileURL.path

        guard parent == paths.recordings.standardizedFileURL.path else { return }

        try? FileManager.default.removeItem(at: folder)
    }
}
