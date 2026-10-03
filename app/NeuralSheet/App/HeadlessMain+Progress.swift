import Foundation

/// The tool's two streams. stdout is results only; everything else goes to stderr unbuffered.
nonisolated enum Console {
    /// The real stdout, once ``reserveStandardOutput()`` has moved it aside.
    nonisolated(unsafe) private static var results = FileHandle.standardOutput

    /// Keeps stdout for the results alone: the libraries underneath print their own chatter to file
    /// descriptor 1 (demucs.cpp logs its model load there), so the real stdout is duplicated for
    /// ``out(_:)`` and descriptor 1 is pointed at stderr. Called once, before anything runs.
    static func reserveStandardOutput() {
        let saved = dup(STDOUT_FILENO)

        guard saved >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return }

        results = FileHandle(fileDescriptor: saved, closeOnDealloc: false)
    }

    static func out(_ line: String) {
        results.write(Data((line + "\n").utf8))
    }

    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Without a newline, for the line rewritten in place.
    static func errorRaw(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static var stderrIsTerminal: Bool { isatty(STDERR_FILENO) != 0 }
}

/// The progress on stderr (issue #24 §4): on a terminal one line per file, rewritten in place as
/// the phase and the percentage move; otherwise a plain line per phase, so a log reads cleanly.
/// `--quiet` drops all of it but the failures. Updates arrive from the engine's threads, so
/// `@unchecked Sendable` with `lock` over the state.
nonisolated final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private let quiet: Bool
    private let total: Int
    private let rewrites = Console.stderrIsTerminal

    private var prefix = ""
    private var lastText = ""

    init(quiet: Bool, total: Int) {
        self.quiet = quiet
        self.total = total
    }

    func begin(file: Int, name: String) {
        lock.lock()
        defer { lock.unlock() }

        prefix = total > 1 ? "[\(file)/\(total)] \(name)" : name
        lastText = ""
    }

    func update(_ update: HeadlessTranscription.Update) {
        let text: String

        switch update.phase {
        case .loading: text = "loading"
        case .separating: text = rewrites ? "separating \(Int(update.fraction * 100))%" : "separating"
        case .transcribing: text = rewrites ? "transcribing \(Int(update.fraction * 100))%" : "transcribing"
        case .writing: text = "writing"
        }

        lock.lock()
        defer { lock.unlock() }

        show(text)
    }

    func finish(_ outcome: HeadlessTranscription.Outcome) {
        var parts: [String] = []

        if let count = outcome.noteCount {
            parts.append(count == 1 ? "done, 1 note" : "done, \(count) notes")
        }

        if !outcome.skipped.isEmpty {
            let names = outcome.skipped.map(\.lastPathComponent).joined(separator: ", ")
            parts.append("skipped \(names) (already there; --replace overwrites)")
        }

        lock.lock()
        defer { lock.unlock() }

        show(parts.joined(separator: "; "), final: true)
    }

    /// Shown even with `--quiet`.
    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        if rewrites, !quiet, !lastText.isEmpty {
            Console.errorRaw("\r\u{1B}[K")
        }

        Console.error("\(prefix): failed: \(message)")
        lastText = ""
    }

    /// Under `lock`.
    private func show(_ text: String, final: Bool = false) {
        guard !quiet, text != lastText || final else { return }

        lastText = text

        if rewrites {
            Console.errorRaw("\r\u{1B}[K\(prefix): \(text)" + (final ? "\n" : ""))
        } else {
            Console.error("\(prefix): \(text)")
        }
    }
}
