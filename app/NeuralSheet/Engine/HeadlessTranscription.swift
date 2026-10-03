import Foundation
import NeuralSheetCore

/// The transcription pipeline with no window (batch and CLI design §2): load, optionally separate
/// the stems, transcribe, optionally detect the tempo, the key and the chords, and write MIDI,
/// MusicXML or a `.neuralsheet` project. The batch window, the `neuralsheet` tool and the Shortcuts
/// actions all run through here, so their files are the ones the app would have saved.
///
/// One instance per batch: it keeps the transcription checkpoint loaded from one file to the next
/// (`TranscriptionEngine(retainsModel:)`). One run at a time; `run` is not reentrant.
///
/// `@unchecked Sendable`: the engine and the separator are themselves thread-safe, and the stored
/// lets never change.
nonisolated final class HeadlessTranscription: @unchecked Sendable {
    typealias Output = TranscriptionOutput

    struct Request: Sendable {
        var input: URL
        var model: ModelSize
        /// Empty is Automatic.
        var instruments: [InstrumentGroup] = []
        var stems = false
        var outputs: Set<Output> = [.midi]
        var detect = false
        /// Nil writes each output beside its input.
        var outDirectory: URL?
        var replace = false
    }

    enum Phase: Sendable, Equatable {
        case loading, separating, transcribing, writing
    }

    /// Where a run is: the phase, and the whole file's progress, 0…1.
    struct Update: Sendable, Equatable {
        var phase: Phase
        var fraction: Double
    }

    /// What a run did.
    struct Outcome: Sendable, Equatable {
        var written: [URL] = []
        /// Outputs that were already there and were left alone (Replace existing off).
        var skipped: [URL] = []
        /// The notes transcribed; nil when every output was skipped and nothing ran.
        var noteCount: Int?
    }

    /// Why a run stopped, worded the same for every door.
    enum Failure: Error, Equatable, Sendable {
        case modelNotInstalled(ModelSize)
        case noModelInstalled
        case notFound
        case unreadable
        case tooShort
        case separation(String)
        case transcription(String)
        case couldNotWrite(String)
        case cancelled

        /// A missing model fails every file alike: the tool exits 2 rather than 1.
        var isSetupError: Bool {
            switch self {
            case .modelNotInstalled, .noModelInstalled: true
            default: false
            }
        }

        var message: String {
            switch self {
            case let .modelNotInstalled(size):
                "The \(size.displayName) model is not installed. Download it in NeuralSheet › Settings › Model."
            case .noModelInstalled:
                "No transcription model is installed. Download one in NeuralSheet › Settings › Model."
            case .notFound:
                "The file could not be found."
            case .unreadable:
                "Could not load the file. Check your file format (Accepted formats: \(AudioFileLoader.acceptedFormatsList))."
            case .tooShort:
                "The audio is shorter than a second."
            case let .separation(reason):
                "Transcription failed. The stems could not be separated: \(reason)."
            case let .transcription(reason):
                reason.isEmpty
                    ? "Transcription failed. The transcription model could not be loaded or run."
                    : "Transcription failed. The transcription model could not be loaded or run: \(reason)."
            case let .couldNotWrite(reason):
                "Could not write the file: \(reason)"
            case .cancelled:
                "Cancelled."
            }
        }
    }

    typealias ProgressHandler = @Sendable (Update) -> Void
    typealias CancelCheck = @Sendable () -> Bool

    /// The rate the take is decoded to for playback; nothing plays it here, so it is the stems
    /// model's own, which spares the separation a resample.
    static let decodeRate = 44_100.0

    /// The model's input rate, and the least audio a run accepts: one second.
    static let minimumSamples = 16_000

    let store: ModelStore
    let settings: GlobalSettings

    private let engine = TranscriptionEngine(retainsModel: true)
    /// Shared with the stems-only run in `+Stems.swift`.
    let separator = StemSeparator()

    init(store: ModelStore = ModelStore(paths: .standard),
         settings: GlobalSettings = GlobalSettings.load(from: AppPaths.standard.globalSettings)) {
        self.store = store
        self.settings = settings
    }

    // MARK: - Models

    /// The model a door uses when none was named: the one chosen in Settings, else any installed.
    func defaultModel() -> ModelSize? {
        store.resolve(preferred: settings.modelSize)
    }

    /// The setup error `request` would hit, checked before anything is read: the CLI exits 2 on it
    /// and the batch window refuses Start.
    func check(model: ModelSize, stems: Bool) -> Failure? {
        guard store.installedPath(for: model) != nil else { return .modelNotInstalled(model) }
        guard !stems || store.installedPath(for: .stems) != nil else { return .modelNotInstalled(.stems) }

        return nil
    }

    // MARK: - Inputs

    /// Files and folders to the files a batch runs over (issue #24 §2): a folder becomes the
    /// accepted audio and video files inside it, recursively, in path order; a file is kept as it
    /// is, so one of the wrong kind fails on its own row rather than vanishing. Repeats go.
    static func expandInputs(_ urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var seen = Set<String>()
        var files: [URL] = []

        func add(_ url: URL) {
            let url = url.standardizedFileURL

            if seen.insert(url.path).inserted {
                files.append(url)
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false

            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                add(url)
                continue
            }

            let found = (manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .allObjects as? [URL]) ?? []

            found
                .filter { AudioFileLoader.acceptedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .forEach(add)
        }

        return files
    }

    // MARK: - Run

    func run(_ request: Request, progress: @escaping ProgressHandler,
             isCancelled: @escaping CancelCheck) async -> Result<Outcome, Failure> {
        if let failure = check(model: request.model, stems: request.stems) { return .failure(failure) }

        guard let modelPath = store.installedPath(for: request.model) else {
            return .failure(.modelNotInstalled(request.model))
        }

        guard FileManager.default.fileExists(atPath: request.input.path) else { return .failure(.notFound) }

        // Replace existing off: what is already there is skipped, and a file with nothing left
        // to write is not transcribed at all.
        var outcome = Outcome()
        var targets: [(Output, URL)] = []

        for output in Output.allCases where request.outputs.contains(output) {
            let url = output.url(for: request.input, in: request.outDirectory)

            if !request.replace, FileManager.default.fileExists(atPath: url.path) {
                outcome.skipped.append(url)
            } else {
                targets.append((output, url))
            }
        }

        guard !targets.isEmpty else { return .success(outcome) }

        progress(Update(phase: .loading, fraction: 0))

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeuralSheet-headless-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source: SourceAudio

        switch await load(request.input, scratch: scratch) {
        case let .success(loaded): source = loaded
        case let .failure(failure): return .failure(failure)
        }

        guard source.mono16k.count >= Self.minimumSamples else { return .failure(.tooShort) }
        guard !isCancelled() else { return .failure(.cancelled) }

        let engineNotes: [EngineNote]

        switch await transcribe(source, modelPath: modelPath, request: request, progress: progress,
                                isCancelled: isCancelled) {
        case let .success(notes): engineNotes = notes
        case let .failure(failure): return .failure(failure)
        }

        guard !isCancelled() else { return .failure(.cancelled) }

        progress(Update(phase: .writing, fraction: 1))

        let result = HeadlessResult(engineNotes: engineNotes, source: source, request: request, settings: settings)

        for (output, url) in targets {
            do {
                try result.write(output, to: url)
                outcome.written.append(url)
            } catch {
                return .failure(.couldNotWrite("\(url.lastPathComponent): \(Self.describe(error))"))
            }
        }

        outcome.noteCount = result.document.events.count

        return .success(outcome)
    }

    // MARK: - Load

    /// The take, as the app loads a dropped file: a video's audio extracted first, into `scratch`.
    func load(_ input: URL, scratch: URL) async -> Result<SourceAudio, Failure> {
        let displayName = input.deletingPathExtension().lastPathComponent

        do {
            let audioURL = AudioFileLoader.isVideo(input)
                ? try await VideoAudioExtractor.extract(video: input, into: scratch)
                : input

            return .success(try AudioFileLoader.load(url: audioURL, deviceRate: Self.decodeRate,
                                                     displayName: displayName))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.unreadable)
        }
    }

    // MARK: - Transcribe

    /// The engine over the take, or over its four stems with the instruments each can hold
    /// (stem separation design §2), as the app's run does.
    private func transcribe(_ source: SourceAudio, modelPath: URL, request: Request,
                            progress: @escaping ProgressHandler,
                            isCancelled: @escaping CancelCheck) async -> Result<[EngineNote], Failure> {
        guard request.stems, let stemsPath = store.installedPath(for: .stems) else {
            progress(Update(phase: .transcribing, fraction: 0))

            return await runEngine(samples: source.mono16k, groups: request.instruments, modelPath: modelPath,
                                   isCancelled: isCancelled) { fraction in
                progress(Update(phase: .transcribing, fraction: fraction))
            }
        }

        progress(Update(phase: .separating, fraction: 0))

        let stems: StemSeparator.Stems

        // The separation is the first half of the bar, as in the app.
        switch await separate(source, modelPath: stemsPath, keepTo: nil, isCancelled: isCancelled, onProgress: { value in
            progress(Update(phase: .separating, fraction: Double(value) * 0.5))
        }) {
        case let .success(separated): stems = separated
        case let .failure(failure): return .failure(failure)
        }

        var notes: [EngineNote] = []

        for (index, samples) in stems.all.enumerated() {
            guard !isCancelled() else { return .failure(.cancelled) }

            // A stem too short for the model contributes nothing rather than failing the run.
            guard samples.count >= Self.minimumSamples else { continue }

            let groups = AppModel.stemGroups(stem: index, selected: request.instruments)

            switch await runEngine(samples: samples, groups: groups, modelPath: modelPath, isCancelled: isCancelled,
                                   onProgress: { fraction in
                                       progress(Update(phase: .transcribing, fraction: 0.5 + (Double(index) + fraction) / 8))
                                   }) {
            case let .success(stemNotes): notes.append(contentsOf: stemNotes)
            case let .failure(failure): return .failure(failure)
            }
        }

        return .success(notes)
    }

    /// One engine run, awaited. The engine sees a cancel at its next chunk.
    private func runEngine(samples: [Float], groups: [InstrumentGroup], modelPath: URL,
                           isCancelled: @escaping CancelCheck,
                           onProgress: @escaping @Sendable (Double) -> Void) async -> Result<[EngineNote], Failure> {
        await withCheckedContinuation { continuation in
            engine.run(
                modelPath: modelPath,
                groups: groups.map(\.rawValue),
                samples16k: samples,
                onUpdate: { update in
                    onProgress(Double(update.progress))
                    return !isCancelled()
                },
                completion: { result in
                    switch result {
                    case let .success(notes):
                        continuation.resume(returning: .success(notes))
                    case .failure(.cancelled):
                        continuation.resume(returning: .failure(.cancelled))
                    case let .failure(error):
                        continuation.resume(returning: .failure(.transcription(
                            AppModel.failureReason(error, modelPath: modelPath))))
                    }
                })
        }
    }

    // MARK: - Errors

    static func describe(_ error: Error) -> String {
        if let error = error as? ProjectError, case let .couldNotWrite(reason) = error { return reason }

        return error.localizedDescription
    }
}
