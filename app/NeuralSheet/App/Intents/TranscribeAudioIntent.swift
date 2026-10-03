import AppIntents
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// Shortcuts → Transcribe Audio (issue #24 §6): files in, the written files out, through the
/// headless pipeline and without opening a window. Each file's progress shows in Shortcuts; a
/// failure stops the action with the words the batch window and the tool use.
struct TranscribeAudioIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Transcribe Audio"
    static let description = IntentDescription(
        "Transcribes audio or video files with NeuralSheet into MIDI, MusicXML or NeuralSheet projects.")
    static let openAppWhenRun = false

    @Parameter(title: "Files", supportedContentTypes: [.audio, .movie])
    var files: [IntentFile]

    @Parameter(title: "Model", description: "None chosen uses the model chosen in NeuralSheet's Settings.")
    var model: IntentModel?

    @Parameter(title: "Instruments", description: "None chosen lets the model choose.")
    var instruments: [IntentInstrument]?

    @Parameter(title: "Separate Stems", default: false)
    var stems: Bool

    @Parameter(title: "Outputs", default: [.midi])
    var outputs: [IntentOutput]

    @Parameter(title: "Detect Tempo and Key", default: false)
    var detect: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$files) to \(\.$outputs)") {
            \.$model
            \.$instruments
            \.$stems
            \.$detect
        }
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let pipeline = HeadlessTranscription()

        guard let size = model?.size ?? pipeline.defaultModel() else {
            throw IntentFailure(HeadlessTranscription.Failure.noModelInstalled.message)
        }

        if let failure = pipeline.check(model: size, stems: stems) {
            throw IntentFailure(failure.message)
        }

        let chosenOutputs = Set((outputs.isEmpty ? [.midi] : outputs).map(\.output))
        let workspace = try IntentWorkspace()
        let progress = self.progress
        let cancel = CancelFlag()
        var results: [IntentFile] = []

        progress.totalUnitCount = Int64(files.count * 100)

        for (index, file) in files.enumerated() {
            let input = try workspace.input(file)
            let request = HeadlessTranscription.Request(
                input: input, model: size, instruments: IntentInstrument.groups(instruments ?? []), stems: stems,
                outputs: chosenOutputs, detect: detect, outDirectory: workspace.outputs, replace: true)
            let base = Int64(index * 100)

            let result = await withTaskCancellationHandler {
                await pipeline.run(request, progress: { update in
                    progress.completedUnitCount = base + Int64(update.fraction * 100)
                }, isCancelled: { cancel.isRaised })
            } onCancel: {
                cancel.raise()
            }

            switch result {
            case let .success(outcome):
                results += outcome.written.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) }
            case .failure(.cancelled):
                throw CancellationError()
            case let .failure(failure):
                throw IntentFailure(files.count > 1 ? "\(file.filename): \(failure.message)" : failure.message)
            }
        }

        progress.completedUnitCount = progress.totalUnitCount

        return .result(value: results)
    }
}

/// An action's failure, shown by Shortcuts as it is.
nonisolated struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// Already in the user's language (`HeadlessTranscription.Failure.message`): handed over as
    /// it is, not as a key.
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Where an action works: the files handed in, copied out when they come as data, and the folder
/// its results are written to, which it hands back to Shortcuts and never deletes itself. Folders a
/// day old are swept when the next action starts.
nonisolated struct IntentWorkspace {
    let root: URL
    let outputs: URL
    private let inputs: URL

    static var parent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NeuralSheet-Shortcuts", isDirectory: true)
    }

    init() throws {
        IntentWorkspace.sweep()

        root = IntentWorkspace.parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputs = root.appendingPathComponent("out", isDirectory: true)
        inputs = root.appendingPathComponent("in", isDirectory: true)

        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
    }

    /// The file on disk under its own name: its URL when Shortcuts gave one that can be read,
    /// otherwise its data written out.
    func input(_ file: IntentFile) throws -> URL {
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            if FileManager.default.isReadableFile(atPath: url.path) {
                let copy = inputs.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                return copy
            }
        }

        let name = file.filename.isEmpty ? "Audio" : file.filename
        let destination = inputs.appendingPathComponent(name)
        try file.data.write(to: destination, options: .atomic)

        return destination
    }

    private static func sweep() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        guard let entries = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])
        else { return }

        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast

            if created < cutoff {
                try? manager.removeItem(at: entry)
            }
        }
    }
}
