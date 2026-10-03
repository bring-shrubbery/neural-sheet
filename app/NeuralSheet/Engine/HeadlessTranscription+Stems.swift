import Foundation
import NeuralSheetCore

/// The separator without a window: awaited inside a transcription run, and on its own for the
/// Separate Stems action (issue #24 §6), which hands out the four stems as files.
extension HeadlessTranscription {
    /// The separator, awaited. The library cannot be stopped, so a cancel abandons the run: its
    /// completion is dropped and this returns at once (the poll is a fifth of a second).
    func separate(_ source: SourceAudio, modelPath: URL, keepTo: URL?, isCancelled: @escaping CancelCheck,
                  onProgress: @escaping @Sendable (Float) -> Void) async -> Result<StemSeparator.Stems, Failure> {
        let once = ResumeOnce<Result<StemSeparator.Stems, Failure>>()
        let separator = self.separator

        return await withCheckedContinuation { continuation in
            once.install(continuation)

            separator.run(
                modelPath: modelPath,
                source: source,
                keepTo: keepTo,
                onProgress: onProgress,
                completion: { result in
                    once.resume(with: result.mapError { .separation($0.message) })
                })

            Task.detached {
                while !once.isResumed {
                    if isCancelled() {
                        separator.cancel()
                        once.resume(with: .failure(.cancelled))
                        return
                    }

                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    /// `input`'s four stems as 24-bit stereo `.caf` files in `folder`, named as Export Stems…
    /// names them (`<take> - Drums.caf` …) and listed in its order: drums, bass, vocals, other.
    func separateStems(input: URL, into folder: URL, progress: @escaping @Sendable (Double) -> Void,
                       isCancelled: @escaping CancelCheck) async -> Result<[URL], Failure> {
        guard let modelPath = store.installedPath(for: .stems) else { return .failure(.modelNotInstalled(.stems)) }
        guard FileManager.default.fileExists(atPath: input.path) else { return .failure(.notFound) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeuralSheet-headless-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source: SourceAudio

        switch await load(input, scratch: scratch) {
        case let .success(loaded): source = loaded
        case let .failure(failure): return .failure(failure)
        }

        let kept = scratch.appendingPathComponent("stems", isDirectory: true)
        let stems: StemSeparator.Stems

        switch await separate(source, modelPath: modelPath, keepTo: kept, isCancelled: isCancelled,
                              onProgress: { progress(Double($0)) }) {
        case let .success(separated): stems = separated
        case let .failure(failure): return .failure(failure)
        }

        guard let keptFolder = stems.keptFolder else { return .failure(.couldNotWrite(String(localized: "the stems could not be kept",
                                                                                 comment: "The reason after \"Could not write the file:\""))) }

        let takeName = source.droppedFileName ?? input.deletingPathExtension().lastPathComponent
        var files: [URL] = []

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for stem in StemNames.exportOrder {
                let name = StemNames.exportFileName(takeName: takeName, stem: stem)
                let destination = folder.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("caf")

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: keptFolder.appendingPathComponent(StemNames.cacheFileName(stem: stem)),
                                                 to: destination)
                files.append(destination)
            }
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }

        return .success(files)
    }
}

/// A continuation resumed exactly once, by whichever of two racers gets there first.
/// `@unchecked Sendable`: guarded by `lock`.
nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resumed = false

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: Value) {
        lock.lock()
        let continuation = resumed ? nil : self.continuation
        resumed = true
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}

/// A cancel request any thread can raise and read: the batch's Cancel, an intent's task being
/// cancelled. `@unchecked Sendable`: guarded by `lock`.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}
