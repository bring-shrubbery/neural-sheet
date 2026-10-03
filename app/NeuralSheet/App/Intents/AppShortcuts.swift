import AppIntents

/// NeuralSheet's actions in Shortcuts and Spotlight (issue #24 §6). Transcribe Audio takes files,
/// so a Shortcut built on it can also be offered as a Finder Quick Action, through Shortcuts' own
/// "Use as Quick Action".
nonisolated struct NeuralSheetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TranscribeAudioIntent(),
                    phrases: ["Transcribe audio with \(.applicationName)", "Transcribe with \(.applicationName)"],
                    shortTitle: "Transcribe Audio",
                    systemImageName: "waveform")

        AppShortcut(intent: SeparateStemsIntent(),
                    phrases: ["Separate stems with \(.applicationName)"],
                    shortTitle: "Separate Stems",
                    systemImageName: "square.stack.3d.up")
    }
}
