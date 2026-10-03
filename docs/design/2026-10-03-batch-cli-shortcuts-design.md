# Batch transcription, the command-line tool and Shortcuts — Design

Spec: [issue #24](https://github.com/bring-shrubbery/neural-sheet/issues/24).

The transcription pipeline is spread across `AppModel`'s run, stems and landing code, all of it
main-actor and tied to the window's state machine. This pulls a headless copy of the pipeline
into one type, `HeadlessTranscription`, with no `AppModel` in it, and gives it three callers: a
batch window, a `neuralsheet` executable that runs the app binary in a headless mode, and two
App Intents.

It builds on the stem separation design and the exports' designs. Everything this document does
not mention is unchanged.

## 1. Goals and non-goals

Goals

- One pipeline, three doors; sequential, cancellable, with progress; clear setup errors.

Non-goals

- A standalone binary, a daemon, watch folders, parallel runs.

## 2. Decisions

| Question | Decision |
|---|---|
| The pipeline | `HeadlessTranscription` (`nonisolated`, `Engine/HeadlessTranscription.swift`): `struct Request { input: URL, model: ModelSize, instruments: [InstrumentGroup], stems: Bool, outputs: Set<Output>, detect: Bool, outDirectory: URL?, replace: Bool }`, `enum Output { midi, musicXML, project }`, `func run(_ request:, progress: @Sendable (Progress) -> Void, isCancelled: @Sendable () -> Bool) async -> Result<[URL], Failure>`. It uses `AudioFileLoader` (and the video extractor), `StemSeparator`, `TranscriptionEngine`, `TempoEstimator`/`KeyEstimator`/`ChordDetector`, `MidiFileWriter`, `MusicXMLWriter`, `ProjectPackage`. It keeps one `Transcriber` loaded across calls for the same model (a `HeadlessTranscription` instance is created once per batch). |
| Project output | A `.neuralsheet` written through `ProjectPackage.write` with a `ProjectState` built from defaults plus the detected grid and key, and the audio copied in; it opens in the app like any project. |
| Batch window | `BatchWindow` (SwiftUI, a second `WindowGroup` scene with id `batch`, opened from File → Batch Transcribe…): the controls, a `Table` of `BatchItem`s, Start/Cancel/Done. A `BatchController` (`@Observable`, main actor) owns the queue and runs items one by one on a detached task, mapping `Progress` to the row. The instruments picker reuses `InstrumentPicker`. |
| Headless mode | `main.swift` replaces `@main` on `NeuralSheetApp`: if `CommandLine.arguments` contains `--headless` as its first argument, `HeadlessMain.run(arguments:)` executes the CLI and `exit`s without ever touching `NSApplication`; otherwise `NeuralSheetApp.main()`. `neuralsheet` is a POSIX shell script at `Contents/Resources/neuralsheet` (the synchronized Resources folder copies it with its executable bit), which follows the `/usr/local/bin` symlink back to the bundle and `exec`s the sibling `Contents/MacOS/NeuralSheet` with `--headless` prepended — so one bundle, one code signature (the script is sealed as a resource), no second copy of the engine. (Amended in implementation: a launcher target would have meant editing `project.pbxproj`, which the rules forbid.) |
| CLI parsing | `CLIArguments.parse([String]) -> Result<CLICommand, CLIError>` in Core, pure, tested. Usage text in one place. Instrument names resolve through `InstrumentGroup.allCases.map(\.name)` plus `all`. |
| CLI output | stdout: one absolute path per written file. stderr: progress (`\r`-rewritten when `isatty(2)`), warnings, errors. Exit codes 0 / 1 / 2 as the issue says. `--quiet` drops the progress lines. |
| Install | `Settings → General → Command-line tool`: Install runs `osascript -e 'do shell script "ln -sf <bundle>/Contents/Resources/neuralsheet /usr/local/bin/neuralsheet" with administrator privileges'` through `Process`; Remove the same with `rm`. The state (installed, and pointing at this bundle or another) is read from the symlink each time the pane appears. |
| Intents | `TranscribeAudioIntent: AppIntent` (`openAppWhenRun = false`): `@Parameter files: [IntentFile]`, model (an `AppEnum` over `ModelSize`), instruments (an `AppEnum` over `InstrumentGroup` with `all`), stems, outputs (`AppEnum` multi), detect; returns `[IntentFile]`. `SeparateStemsIntent` returns four files. Both write into a temporary folder the intent owns and hand the files out as `IntentFile`s. `AppShortcutsProvider` registers both with phrases ("Transcribe \(.applicationName)"). Progress: `IntentFile` has no progress; the intent reports through `ProgressReportingIntent`. |
| Errors | `HeadlessTranscription.Failure` maps to `CLIError` and to `IntentError.message` with the same strings: "The <size> model is not installed. Download it in NeuralSheet › Settings › Model." etc. |

## 3. Core

- `CLIArguments.swift` (+ tests covering every flag, errors, `models`, `--version`).
- `ProjectState` already has an `init()` of defaults; `ProjectPackage.write` is used as is.

## 4. App

- `Engine/HeadlessTranscription.swift` (+ `+Outputs.swift`).
- `App/main.swift`, `App/HeadlessMain.swift`, `App/Intents/TranscribeAudioIntent.swift`,
  `SeparateStemsIntent.swift`, `AppShortcuts.swift`.
- `UI/Batch/BatchWindow.swift`, `BatchController.swift`, `BatchRow.swift`.
- `UI/Settings/GeneralSettingsView.swift`: the Command-line tool section.
- `Resources/neuralsheet`: the launcher script, committed with its executable bit; the release workflow's
  signature of the app seals it with the other resources, so `docs/release.md` is unchanged.
- `NeuralSheetApp.swift`: File → Batch Transcribe… and the `batch` window scene.

## 5. Changelog

"Transcribe many files at once with File → Batch Transcribe…, from the Terminal with the
`neuralsheet` tool (install it in Settings → General), or from Shortcuts with the Transcribe Audio
and Separate Stems actions."
