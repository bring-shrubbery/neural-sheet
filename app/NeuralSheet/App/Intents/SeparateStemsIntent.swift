import AppIntents
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// Shortcuts → Separate Stems (issue #24 §6): one file in, its drums, bass, vocals and the rest out
/// as four 24-bit `.caf` files, without opening a window.
struct SeparateStemsIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Separate Stems"
    static let description = IntentDescription(
        "Separates an audio or video file into drums, bass, vocals and the rest with NeuralSheet.")
    static let openAppWhenRun = false

    @Parameter(title: "File", supportedContentTypes: [.audio, .movie])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Separate the stems of \(\.$file)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let pipeline = HeadlessTranscription()

        // Before the file is copied in: the missing model is the failure to report.
        guard pipeline.store.installedPath(for: .stems) != nil else {
            throw IntentFailure(HeadlessTranscription.Failure.modelNotInstalled(.stems).message)
        }

        let workspace = try IntentWorkspace()
        let input = try workspace.input(file)
        let progress = self.progress
        let cancel = CancelFlag()

        progress.totalUnitCount = 100

        let result = await withTaskCancellationHandler {
            await pipeline.separateStems(input: input, into: workspace.outputs, progress: { fraction in
                progress.completedUnitCount = Int64(fraction * 100)
            }, isCancelled: { cancel.isRaised })
        } onCancel: {
            cancel.raise()
        }

        switch result {
        case let .success(files):
            progress.completedUnitCount = 100
            return .result(value: files.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
        case .failure(.cancelled):
            throw CancellationError()
        case let .failure(failure):
            throw IntentFailure(failure.message)
        }
    }
}
