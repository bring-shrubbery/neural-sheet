import os

/// The extension's log (`log stream --predicate 'subsystem == "com.quassum.neuralsheet.plugin.au"'`):
/// where the models were looked for and what each run did.
nonisolated enum PluginLog {
    static let logger = Logger(subsystem: "com.quassum.neuralsheet.plugin.au", category: "plugin")
}
