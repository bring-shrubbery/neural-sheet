import Foundation

/// Settings → General → Command-line tool (issue #24 §5): what the pane reads and does, so the
/// view keeps to the model's contract. The state is the symlink's, read again on every call.
extension AppModel {
    var commandLineToolState: CommandLineTool.State { CommandLineTool.state() }

    /// The path the pane shows and copies.
    var commandLineToolPath: String { CommandLineTool.linkPath }

    /// Install…: nil when it worked or was cancelled at the password prompt, else the reason.
    func installCommandLineTool() async -> String? {
        await CommandLineTool.install()
    }

    func removeCommandLineTool() async -> String? {
        await CommandLineTool.remove()
    }
}
