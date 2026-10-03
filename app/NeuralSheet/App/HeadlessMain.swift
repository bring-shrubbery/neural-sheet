import Foundation
import NeuralSheetCore

/// The `neuralsheet` command-line tool (issue #24 §4, batch and CLI design §2), served by the app's
/// binary when it is started with `--headless`. stdout carries one absolute path per file written;
/// stderr the progress, the warnings and the errors. Exit 0 when every input succeeded, 1 when any
/// failed, 2 for a usage or setup error.
///
/// No AppKit here or below: the run is a main-actor task on the main dispatch queue, served by
/// `dispatchMain()`, and the process ends with `exit`.
enum HeadlessMain {
    static let flag = "--headless"

    nonisolated enum ExitCode {
        static let success: Int32 = 0
        static let someFailed: Int32 = 1
        static let usage: Int32 = 2
        /// Interrupted with ⌃C: the shell's convention, 128 + SIGINT.
        static let interrupted: Int32 = 130
    }

    /// Runs the tool and exits; never returns.
    static func start(arguments: [String]) -> Never {
        Console.reserveStandardOutput()
        let interrupt = Interrupt()

        Task {
            let code = await run(arguments, interrupt: interrupt)
            exit(code)
        }

        dispatchMain()
    }

    // MARK: - Commands

    static func run(_ arguments: [String], interrupt: Interrupt) async -> Int32 {
        switch CLIArguments.parse(arguments) {
        case let .failure(error):
            Console.error("neuralsheet: \(error.message)\n\n\(CLIArguments.usage)")
            return ExitCode.usage

        case .success(.help):
            Console.out(CLIArguments.usage)
            return ExitCode.success

        case .success(.version):
            Console.out("neuralsheet \(version)")
            return ExitCode.success

        case .success(.models):
            return listModels()

        case let .success(.transcribe(options)):
            return await transcribe(options, interrupt: interrupt)
        }
    }

    /// The app's version and build, as the welcome window shows them.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        return "\(short) (\(build))"
    }

    /// One line per installed model: its name, a tab, its file.
    private static func listModels() -> Int32 {
        let store = ModelStore(paths: .standard)
        let installed = ModelSize.allCases.compactMap { size in store.installedPath(for: size).map { (size, $0) } }

        if installed.isEmpty {
            Console.error("No models are installed. Download them in NeuralSheet › Settings › Model.")
        }

        for (size, path) in installed {
            Console.out("\(size.rawValue)\t\(path.path)")
        }

        return ExitCode.success
    }

    // MARK: - Transcribe

    private static func transcribe(_ options: CLITranscribeOptions, interrupt: Interrupt) async -> Int32 {
        let pipeline = HeadlessTranscription()

        guard let model = options.model ?? pipeline.defaultModel() else {
            Console.error("neuralsheet: \(HeadlessTranscription.Failure.noModelInstalled.message)")
            return ExitCode.usage
        }

        if let failure = pipeline.check(model: model, stems: options.stems) {
            Console.error("neuralsheet: \(failure.message)")
            return ExitCode.usage
        }

        let inputs = HeadlessTranscription.expandInputs(options.inputs.map(resolve))
        let outDirectory = options.outDirectory.map(resolve)
        let progress = ProgressLine(quiet: options.quiet, total: inputs.count)
        var anyFailed = false

        for (index, input) in inputs.enumerated() {
            let request = HeadlessTranscription.Request(
                input: input, model: model, instruments: options.instruments, stems: options.stems,
                outputs: options.outputs, detect: options.detect, outDirectory: outDirectory, replace: options.replace)

            progress.begin(file: index + 1, name: input.lastPathComponent)

            let result = await pipeline.run(request, progress: { progress.update($0) },
                                            isCancelled: { interrupt.isRaised })

            switch result {
            case let .success(outcome):
                progress.finish(outcome)
                outcome.written.forEach { Console.out($0.path) }

            case .failure(.cancelled):
                progress.fail("Cancelled.")
                return ExitCode.interrupted

            case let .failure(failure):
                progress.fail(failure.message)

                if failure.isSetupError { return ExitCode.usage }

                anyFailed = true
            }
        }

        if inputs.isEmpty {
            Console.error("neuralsheet: \(CLIError.noInputs.message)")
            return ExitCode.usage
        }

        return anyFailed ? ExitCode.someFailed : ExitCode.success
    }

    /// A path as typed: `~` expanded, relative to the working directory.
    private static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
    }
}

/// ⌃C during a run: the first stops at the engine's next chunk and exits 130 once the current file
/// is abandoned; a second exits at once. `@unchecked Sendable`: guarded by `lock`.
nonisolated final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            self?.raise()
        }
        source.resume()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    private func raise() {
        lock.lock()
        let again = raised
        raised = true
        lock.unlock()

        if again {
            exit(HeadlessMain.ExitCode.interrupted)
        }
    }
}
