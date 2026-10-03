# NeuralSheet for iPhone and iPad — Design

Spec: [issue #26](https://github.com/bring-shrubbery/neural-sheet/issues/26). This document is
the parent design; the work is cut into sub-issues (§6), each with its own short design where it
needs one.

The engine is pure Swift on Accelerate and Metal; the core package has no AppKit; the audio
layer (`app/NeuralSheet/Audio`, `Engine`) imports only AVFoundation, AudioToolbox, CoreAudio and
Synchronization, with the macOS-only device code already isolated in `PlaybackEngine+Devices`,
`AudioDevices`, `InputAggregate` and `ProcessTap`. The UI is SwiftUI plus AppKit drawing views
whose drawing is CoreGraphics. An iOS app is therefore a new target that compiles the packages,
the audio layer minus the HAL files, the CoreGraphics drawing, and a new SwiftUI/UIKit shell.

## 1. Goals and non-goals

Goals

- Record or import, transcribe on device, listen, correct, export; open and save the same
  `.neuralsheet` packages as the Mac through Files and iCloud Drive.
- Share as much as possible: packages, audio layer, drawing code, commands, exports, strings.
- The Mac app's behaviour and build are unchanged.

Non-goals

- MIDI out, system-audio recording, batch window, CLI, Shortcuts (follow-ups); Watch, visionOS.

## 2. Decisions

| Question | Decision |
|---|---|
| Project | `ios/project.yml` for [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), generating `ios/NeuralSheet-iOS.xcodeproj`, which is committed so Xcode and CI open it without the tool; `make -C ios project` regenerates it. The Mac `project.pbxproj` is never touched. One target `NeuralSheet` (bundle id `com.quassum.neuralsheet.ios`, iOS 26, iPhone + iPad, portrait and landscape), depending on the two local packages by path. |
| Shared sources | The target lists `../app/NeuralSheet/Audio/**` and `../app/NeuralSheet/Engine/**` as sources with `excludes` for the HAL files (`AudioDevices.swift`, `InputAggregate.swift`, `ProcessTap.swift`, `PlaybackEngine+Devices.swift`, `RecordingInput.swift`, `MidiOutput*.swift`, `MidiOutRing.swift`, `InstrumentSynthBank+MidiOut.swift`); the few `#if os(macOS)` fences those exclusions still need in the remaining files are added on the Mac side first (a Mac-only commit each, no behaviour change). `PlaybackEngine` gains a `PlaybackEngine+Session.swift` on the iOS side: `AVAudioSession` category `.playAndRecord` with `.defaultToSpeaker` and `.allowBluetoothA2DP`, route-change and interruption handling (pause on interruption, resume on `.shouldResume`). |
| demucs | `Scripts/build-engine.sh` gains a platform argument (`macos`, `ios`, `iossimulator`) building `libdemucs.a` per platform into `build/engine/<platform>/` with the CMake toolchain flags for `-sdk iphoneos` / `iphonesimulator`; the iOS target's script phase calls it. The bridge `nsheet_stems.cpp` compiles unchanged. |
| Drawing shared | `TimelineDrawing.swift`, `TimelineGeometry.swift`, `WaveformPeaks` use, `PianoRollView`'s draw code, `RulerView`'s, `ScoreRenderer*` are CoreGraphics; the AppKit-specific halves (`NSView` subclassing, mouse handling, `NSPanel` cards) are split off so the drawing functions take a `CGContext` and a geometry and can be called from a `UIView.draw(_:)`. This split is done on the Mac side first (pure moves, the `+Drawing.swift` suffix), so the iOS views are thin `UIView`s calling the same functions. |
| Model | `AppModel` is macOS-shaped (NSWindow, panels, menus). iOS gets `MobileModel` (`@Observable`, main actor) built from the same pieces: `PlaybackEngine`, `TranscriptionEngine`, `NoteDocument`, `EditorState`, `ProjectState`, with the pure command methods lifted into a `ProjectCommands` protocol-free Swift file shared by both (`AppModel+Editing` logic that does not touch AppKit moves to `Shared/EditingCommands.swift` compiled by both targets — again Mac-side first, pure move). |
| Documents | SwiftUI `DocumentGroup(newDocument:)` over a `ReferenceFileDocument` wrapping `ProjectPackage` (a package UTType `com.quassum.neuralsheet.project`, exported in both Info.plists; the Mac already declares it). Files, iCloud Drive and the document browser come with it; autosave is the document's, not ours (the Mac has none by design; iOS documents autosave by platform convention, noted as an iOS departure). |
| Screens | `TranscribeScreen` (waveform, record/import bar, model + instruments sheet, Stems toggle, progress, Transcribe), `RollScreen` (the timeline with touch gestures, a bottom toolbar with the tools, a note card as a sheet/popover), `ScoreScreen` (read-only, follow playhead, tap to seek), the transport bar (play, position, mix, speed, loop) pinned under every screen, `SettingsScreen` (models with download, sound bank from Files, audio). Tabs on iPhone; a three-column split on iPad (sidebar strips, content, inspector). |
| Touch | One-finger pan scrolls; pinch zooms horizontally, two-finger vertical pinch zooms pitch; tap selects, tap empty seeks, long-press opens the note card; drag a selected note moves it (with the audition); drag its ends resizes; two-finger tap = undo (system). Hit targets are 44 pt minimum: the roll adds an invisible margin around thin notes. |
| Imports | Files (`fileImporter` with the audio and video UTTypes, through `AudioFileLoader` / `VideoAudioExtractor`), Photos (`PhotosPicker` videos), the share sheet (`CFBundleDocumentTypes` + `onOpenURL`), and recording with `AVAudioSession` (the count-in and click reuse the Mac code). |
| Models | `ModelDownloader` unchanged (URLSession, resume, SHA-256); storage under the app's Application Support; the large model offered when `ProcessInfo.physicalMemory ≥ 8 GiB`. |
| Background | A run holds a `UIApplication.beginBackgroundTask` and shows a Live Activity (ActivityKit) with the file name and percentage; if the system ends the task before the run finishes, the run is cancelled cleanly and resumed from the start on return (chunks are not checkpointed in v1). Thermal: `ProcessInfo.thermalState` `.serious`/`.critical` pauses between chunks and the Live Activity says "Paused — cooling down". |
| Exports | MIDI, MusicXML, PDF, audio through `ShareLink` / `fileExporter`; iPad drag of a `.mid` through `onDrag` with an `NSItemProvider` file representation. |
| Settings & strings | `GlobalSettings` shared; `Localizable.xcstrings` shared by path (the iOS target references the same catalogs; iOS-only strings go in `ios/NeuralSheet/Localizable.xcstrings`). |
| CI | A second job in the release workflow builds the iOS target for the simulator on every push and archives for TestFlight on `main` when the App Store Connect key secrets exist (upload is a maintainer-enabled step; the build must stay green without the secrets). |

## 3. What moves on the Mac side first (no behaviour change)

1. `#if os(macOS)` fences in the audio layer where a HAL symbol is referenced from a shared file.
2. Drawing split: `PianoRollView+Drawing.swift`, `RulerView+Drawing.swift`, `WaveformView+Drawing.swift`, `KeyboardView+Drawing.swift`, `ChordLaneView+Drawing.swift`, `ScoreRenderer` is already pure — each a free function or a `nonisolated` struct taking `CGContext`, geometry and a snapshot.
3. `Shared/EditingCommands.swift`: the pure parts of `AppModel+Editing`, `+BulkEditing`, `+Clipboard` (pasteboard excluded), `+Versions`, `+Chords`, `+Markers`, `+Lyrics` that compute a batch from a document and state.

Each is a sub-issue's first task and is landed and released on the Mac before the iOS code that uses it.

## 4. Order of work (sub-issues)

A. Scaffold: xcodegen spec, target, packages linked, demucs for iOS, CI simulator build, a window that says the version.
B. Shared audio on iOS: fences, `AVAudioSession`, `PlaybackEngine` playing a bundled test take with the synth; recording.
C. Documents: UTType, `ReferenceFileDocument`, `DocumentGroup`, open a Mac-saved package, save, reopen on the Mac.
D. Transcribe screen: imports, record, models and downloads, instruments, Stems, progress, Live Activity, thermal pause.
E. Roll drawing shared and the touch roll: pan/zoom/select/seek, keyboard and ruler, playhead follow.
F. Editing on touch: move/resize/pitch/velocity/instrument, note card, bulk commands menu, undo/redo, versions list.
G. Score screen.
H. Transport, mix, speed, loop, click; Settings (sound bank from Files, count-in, audio).
I. Exports and iPad drag.
J. Accessibility and German/Spanish parity; VoiceOver pass on device.
K. TestFlight: archive job, signing with the maintainer's secrets, release notes.

## 5. Checks

Every sub-issue: the Mac build and tests unchanged; the iOS target builds warning-free for the simulator; an XCUITest per screen as they arrive (record → transcribe → export at the end). The acceptance scenarios in #26 are run on a real iPhone and iPad by a maintainer before TestFlight.

## 6. Changelog

(Each sub-issue adds nothing to the Mac changelog; the iOS app gets its own `ios/CHANGELOG.md`
with "NeuralSheet for iPhone and iPad: record or import a take, transcribe it on the device, fix
the notes on the piano roll, and export MIDI, MusicXML, PDF or audio." as its first entry.)
