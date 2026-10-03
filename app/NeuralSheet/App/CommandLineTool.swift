import Foundation

/// The `neuralsheet` symlink in `/usr/local/bin` (issue #24 §5): Settings → General installs it,
/// removes it and shows where it points. The link targets the launcher script inside this bundle,
/// so it follows the app through updates in place; one left by a copy elsewhere is reported as such.
nonisolated enum CommandLineTool {
    static let linkPath = "/usr/local/bin/neuralsheet"

    /// The launcher, `Contents/Resources/neuralsheet`.
    static var launcherPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/neuralsheet").path
    }

    enum State: Equatable {
        case notInstalled
        /// The link points at this bundle's launcher.
        case installed
        /// A link to another copy of the app, or a file that is not ours.
        case other(String)
    }

    /// Read from the file system each time: nothing is remembered.
    static func state() -> State {
        let manager = FileManager.default

        guard let destination = try? manager.destinationOfSymbolicLink(atPath: linkPath) else {
            return manager.fileExists(atPath: linkPath) ? .other(linkPath) : .notInstalled
        }

        let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: "/usr/local/bin/"))
            .standardizedFileURL.path

        return resolved == URL(fileURLWithPath: launcherPath).standardizedFileURL.path ? .installed : .other(resolved)
    }

    /// Creates the link, asking for the administrator password through the system's own prompt.
    /// Nil when it worked or the prompt was cancelled; otherwise what went wrong.
    static func install() async -> String? {
        await runPrivileged("mkdir -p /usr/local/bin && ln -sf \(shellQuoted(launcherPath)) \(shellQuoted(linkPath))")
    }

    static func remove() async -> String? {
        await runPrivileged("rm -f \(shellQuoted(linkPath))")
    }

    // MARK: - Privileges

    /// `do shell script … with administrator privileges` through `osascript`, off the main actor.
    private static func runPrivileged(_ command: String) async -> String? {
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"

        return await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }

            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else { return nil }

            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            // -128 is the password prompt's Cancel: the user chose not to, nothing failed.
            return message.contains("-128") ? nil : (message.isEmpty ? "The command failed." : message)
        }.value
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
