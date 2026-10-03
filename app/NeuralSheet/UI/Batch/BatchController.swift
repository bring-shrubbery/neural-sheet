import AppKit
import Foundation
import NeuralSheetCore

/// One file in the batch and where it has got to (issue #24 §2).
struct BatchItem: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        case loading
        case separating(Double)
        case transcribing(Double)
        case writing
        /// `notes` is nil when every output was already there and nothing ran.
        case done(notes: Int?, skipped: Int)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var state: State = .waiting
    /// The files this item wrote, for Done to show.
    var written: [URL] = []
}

/// File → Batch Transcribe…'s queue and settings (batch and CLI design §2): the files run one by
/// one through a `HeadlessTranscription` made for the batch, so one model is in memory and it is
/// loaded once. Cancel stops after the file in hand.
@Observable final class BatchController {
    var items: [BatchItem] = []

    var model: ModelSize?
    /// Empty is Automatic.
    var instruments: [InstrumentGroup] = []
    var stems = false
    var outputs: Set<TranscriptionOutput> = [.midi]
    var detect = false
    /// Nil writes each file's outputs beside it.
    var outDirectory: URL?
    var replace = false

    private(set) var isRunning = false
    private(set) var cancelRequested = false
    /// A missing model, said under the controls instead of starting.
    private(set) var setupError: String?

    /// Made at Start, with the app's current settings (the After transcription filter, the MIDI
    /// overflow rule), and kept for the batch so the model stays loaded.
    @ObservationIgnored private var pipeline: HeadlessTranscription?

    // MARK: - The list

    /// Files and folders dropped or chosen: folders become the audio inside them; files already in
    /// the list are not added twice.
    func add(_ urls: [URL]) {
        let present = Set(items.map(\.url.path))

        items += HeadlessTranscription.expandInputs(urls)
            .filter { !present.contains($0.path) }
            .map { BatchItem(url: $0) }
    }

    /// Only rows that are not running.
    func remove(_ ids: Set<BatchItem.ID>) {
        items.removeAll { ids.contains($0.id) && !isActive($0) }
    }

    func clearFinished() {
        items.removeAll {
            switch $0.state {
            case .done, .failed: true
            default: false
            }
        }
    }

    private func isActive(_ item: BatchItem) -> Bool {
        switch item.state {
        case .loading, .separating, .transcribing, .writing: true
        default: false
        }
    }

    // MARK: - Running

    var canStart: Bool {
        !isRunning && model != nil && !outputs.isEmpty && items.contains { $0.state == .waiting }
    }

    /// Whether anything was written, for Done.
    var hasResults: Bool { items.contains { !$0.written.isEmpty } }

    func start(settings: GlobalSettings) {
        guard canStart, let model else { return }

        let pipeline: HeadlessTranscription

        if let existing = self.pipeline, existing.settings == settings {
            pipeline = existing
        } else {
            pipeline = HeadlessTranscription(settings: settings)
        }

        if let failure = pipeline.check(model: model, stems: stems) {
            setupError = failure.message
            return
        }

        self.pipeline = pipeline
        setupError = nil
        isRunning = true
        cancelRequested = false

        Task {
            await runQueue(pipeline)
        }
    }

    /// Stops once the file in hand is finished.
    func cancel() {
        guard isRunning else { return }

        cancelRequested = true
    }

    /// Opens what was written: the output folder when there is one, else the files in the Finder.
    func revealResults() {
        if let outDirectory {
            NSWorkspace.shared.open(outDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(items.flatMap(\.written))
        }
    }

    /// The waiting files one at a time, picking up any added meanwhile, with the settings read
    /// afresh for each.
    private func runQueue(_ pipeline: HeadlessTranscription) async {
        queue: while !cancelRequested, let index = items.firstIndex(where: { $0.state == .waiting }), let model {
            let id = items[index].id
            let request = HeadlessTranscription.Request(
                input: items[index].url, model: model, instruments: instruments, stems: stems, outputs: outputs,
                detect: detect, outDirectory: outDirectory, replace: replace)

            setState(.loading, for: id)

            // Held for the file's run only: the closure goes with it.
            let controller = self
            let result = await pipeline.run(request, progress: { update in
                Task { @MainActor in controller.apply(update, to: id) }
            }, isCancelled: { false })

            switch result {
            case let .success(outcome):
                setState(.done(notes: outcome.noteCount, skipped: outcome.skipped.count), for: id)
                if let row = items.firstIndex(where: { $0.id == id }) { items[row].written = outcome.written }
            case let .failure(failure):
                setState(.failed(failure.message), for: id)

                // A missing model fails every file alike: stop rather than fail them all.
                if failure.isSetupError {
                    setupError = failure.message
                    break queue
                }
            }
        }

        isRunning = false
        cancelRequested = false
    }

    /// From the engine's threads, hopped here. Late updates for a finished row are dropped, and a
    /// percentage is only written when it moves by a whole point.
    private func apply(_ update: HeadlessTranscription.Update, to id: BatchItem.ID) {
        guard let row = items.firstIndex(where: { $0.id == id }), isActive(items[row]) else { return }

        let percent = (update.fraction * 100).rounded(.down) / 100
        let state: BatchItem.State =
            switch update.phase {
            case .loading: .loading
            case .separating: .separating(percent)
            case .transcribing: .transcribing(percent)
            case .writing: .writing
            }

        if items[row].state != state { items[row].state = state }
    }

    private func setState(_ state: BatchItem.State, for id: BatchItem.ID) {
        guard let row = items.firstIndex(where: { $0.id == id }) else { return }

        items[row].state = state
    }
}
