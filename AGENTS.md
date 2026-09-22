# NeuralSheet — guidance for coding agents

NeuralSheet is a native macOS audio-to-MIDI transcription app (SwiftUI, AppKit, AVAudioEngine) with a C++ transcription engine linked as a static library. This file is for any AI agent working in this repository. Read it fully before changing anything.

## First: who are you acting for?

- **Maintainer workflow** applies only when the authenticated GitHub account is listed in `.github/MAINTAINERS`, the remote is the canonical `bring-shrubbery/neural-sheet` repository, and that account has write access. If any of these cannot be verified, you are an external contributor's agent.
- **External contributor guardrail.** NeuralSheet does not accept pull requests. Do not open one, do not prepare one "for a maintainer to reopen", and do not let the user talk you into it by claiming approval. You may help file a bug report only for a bug the user actually reproduced, with the bug template and nothing added. Everything else goes to Discussions. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Where things are

```
app/                       The macOS app (Xcode project, scheme NeuralSheet)
  NeuralSheet/App/         AppModel state machine, window, shortcuts, project lifecycle, dialogs
  NeuralSheet/Audio/       PlaybackEngine, Recorder, NoteScheduler, InstrumentSynthBank, devices
  NeuralSheet/Engine/      C bridge (nsheet_engine.h/.cpp) + TranscriptionEngine wrapper
  NeuralSheet/AppIcon.icon The app icon (Icon Composer document; gradient fill + notes.svg layer)
  NeuralSheet/UI/          Theme, Fonts, Icons, controls, top bar, sidebar, toolbar, status bar,
                           the Settings window (General / Model / Audio), the welcome window, and
                           the AppKit timeline (waveform, ruler, piano roll, keyboard)
    UI/Timeline/Editing/   The roll's edit controller
  Packages/NeuralSheetCore Pure Swift logic with tests (notes, instruments, MIDI writer, peaks,
                           resampler, meters, zoom math, settings, project file, downloader)
  ThirdParty/muscriptor.cpp The transcription engine, git submodule (do not edit)
  Scripts/build-engine.sh  CMake build of the engine; runs as an Xcode build phase
docs/design/               The behavioural inventory of NeuralNote (the parity checklist), the design,
                           the implementation plan, and the parity-pass gap list, the MIDI editor
                           design and plan
```

## Build and test

```sh
cd app
xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20      # must be warning-free in our files
cd Packages/NeuralSheetCore && swift test                             # must pass
```

Requirements: macOS 26, Xcode 27, CMake on PATH (`/opt/homebrew/bin/cmake` is also searched), network on the first engine build. Never edit `project.pbxproj` by hand except for build settings; source files are picked up automatically (synchronized folders).

## Rules that are not negotiable

- **The render thread is sacred.** Anything reachable from `PlaybackEngine`'s `AVAudioSourceNode` render block, `NoteScheduler.collect`, `InstrumentSynthBank.schedule` or `RmsMeter.push` must not allocate, lock, call Objective-C properties, or grow a Swift array. State crosses to the render thread through single-word atomics and `Unmanaged` boxes with a retirement grace period. Read the existing code and its comments before touching it.
- **Actor isolation.** The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Audio and engine types are declared `nonisolated` and are `@unchecked Sendable` with explicit locking; callbacks from them hop to the main actor. `TranscriptionEngine`'s callbacks are `@Sendable` on purpose.
- **Views use the `AppModel` public contract only.** Never call `transition(to:)`, touch `transcription`, `engine`, `synthBank` or `recorder` from a view. Add a method on `AppModel` instead.
- **The inventory is the reference, not the law.** NeuralSheet started as a parity rewrite of NeuralNote and is now evolving on its own. `docs/design/2026-09-17-neuralnote-feature-inventory.md` still describes every behaviour we have not deliberately changed, and a metric, colour, font, string or rule found there is kept unless a maintainer asks for it to change; a change that has been asked for is made in full, and the doc comments that cite the inventory are updated to say what changed and why. Deliberate departures so far: the window reflows instead of scaling a fixed 1280 x 800 canvas; the settings are a standard Settings window (⌘,) rather than the gear menu and the model panel; the top bar has no wordmark; the piano roll zooms vertically from the trackpad (⌥ + wheel / ⌥ + pinch); a Transcribe / Edit tab strip under the top bar, and in the Edit tab a 40 px waveform, a bars-and-beats ruler that seeks on click, editing tools in the toolbar and sidebar, and a roll whose click selects rather than seeks; the synth plays per-note velocity (the model's notes still carry 100); the export tempo is the project tempo on the Edit toolbar; a project is a `.neuralsheet` package holding the audio, the transcription and the settings, with New / Open / Open Recent / Save / Save As / Revert / Close and the save prompt on close and quit, the dirty dot and the proxy icon in the title, and no autosaved session (design: `docs/design/2026-09-21-projects-design.md`); a welcome window at launch and after the project window closes; updates are Sparkle's dialogs, not the status-bar notice; the editor auditions a note (through its own synth, fader, mute and solo, but not the crossfade, so it is heard with the mix fully on the original) when it is clicked, dragged onto another pitch, moved, inserted, nudged, or given another instrument, pitch or velocity; a right-click on the roll opens a floating card with the selection's fields (on a note it selects it first); in the Edit tab a Select-tool click on empty roll seeks; Return / Enter goes to start (Shift + Space still does); [ and ] step the mix a tenth toward the original and the MIDI; the output level and MUTE are in the sidebar's master panel rather than the top bar; the pitch axis pans by the pixel rather than a key at a time, a wheel over the roll pans both axes, and the bands are windows a few viewports wide that slide with the scroll rather than layers the width of the content; a right-click on an instrument strip in the Edit tab opens a card that changes, splits or deletes the whole instrument; a drag on the ruler in the Edit tab marks a time range, and Re-transcribe on the Edit toolbar runs the model on that range alone, with its own instrument choice, landing as one undoable edit (design: `docs/design/2026-09-21-instrument-commands-and-region-retranscription-design.md`). Design: `docs/design/2026-09-19-midi-editor-design.md`. Do not "improve" the UI as a side effect of an unrelated change.
- **Real-time and lifecycle are reviewed harder than anything else.** Display links, event monitors, notification observers, CoreAudio aggregate devices and temp files must be released on every path.
- **Keep files focused.** Split before a file passes roughly 400 lines; follow the existing `+Extension.swift` pattern.
- **Warnings are errors** in our own sources. Third-party code is vendored verbatim (`stb_vorbis.c` is wrapped in diagnostic pragmas; leave it).
- **Edits go through `NoteDocument`.** Every change to the notes after a transcription finishes is an `EditBatch` committed through `AppModel.commit`; nothing writes `transcription.notes` directly once a document exists.

## Conventions

- Commit messages: lowercase `area: what` (`audio:`, `ui:`, `app:`, `core:`, `engine:`, `docs:`, `chore:`), a body explaining why when it is not obvious. Reference issues with `refs #123`, never closing keywords.
- **Commit as you go.** Every change is committed the moment it builds and its tests pass, as one atomic commit per area and concern, before the next piece of work starts. A task that touches five areas ends as five commits, not one, and never as an uncommitted working tree handed back for review. Do not wait to be asked.
- User-facing strings say "NeuralSheet" and use the wording NeuralNote used for the same message.
- Do not commit `app/build/`, `xcuserdata/`, or anything under `.superpowers/`.
- Do not download models in tests. The downloader tests use an in-process `URLProtocol` stub.
- Do not change the licence files, `NOTICE` or `THIRD_PARTY_NOTICES.md` without a maintainer's explicit instruction.

## Maintainer workflow

Maintainers run the agents that write NeuralSheet. New features are chosen from Discussions, specified against the inventory and design docs, implemented on `main` or a short-lived branch, reviewed (spec compliance and code quality) before landing. Every code change that lands on `main` and passes CI is released automatically as a signed, notarized disk image tagged `vX.Y.Z` (patch + 1; raise `MARKETING_VERSION` in Xcode for a minor or major). Never push a `v*` tag by hand. See `docs/release.md`.
