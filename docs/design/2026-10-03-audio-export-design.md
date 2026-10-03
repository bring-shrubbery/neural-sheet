# Exporting stems and rendered audio — Design

Spec: [issue #22](https://github.com/bring-shrubbery/neural-sheet/issues/22).

The separator produces 44.1 kHz stereo stems and folds them to 16 kHz mono for the model; the
stereo set is dropped. The synth graph renders only live. This keeps the stereo stems on disk for
the life of the take and writes them out on request, and renders the MIDI (or the mix) through a
second `AVAudioEngine` in manual rendering mode, built from the same synth bank code.

It builds on the stem separation design and the playback design §4. Everything this document
does not mention is unchanged.

## 1. Goals and non-goals

Goals

- Export Stems… from a kept separation or a fresh one; Export Audio… offline, with the live
  engine untouched, in three formats and three mixes.

Non-goals

- MIDI stems per instrument, normalisation, dither, sample-rate choice, the click.

## 2. Decisions

| Question | Decision |
|---|---|
| Keeping the stems | `StemSeparator.separate` gains `keepTo: URL?`: when set, each stem's stereo 44.1 kHz buffer is written as 24-bit `.caf` into that folder (`Drums.caf`, `Bass.caf`, `Vocals.caf`, `Other.caf`) as it is produced. `AppModel+Stems` passes `paths.recordings/stems-<uuid>/`; `stemsFolder` is remembered on the model beside the take and cleared (folder removed) by `clearNow`, `deleteRecordedFiles` and the launch sweep (the recordings sweep already removes everything there). |
| Export Stems… | `AppModel+StemsExport.swift`: `canExportStems` = a take is loaded, no run in flight, and (`stemsFolder != nil` or the Stems model is installed). Without a folder: `runSeparationOnly()` reuses `StemsJob` with phase `.separating` and no transcription step (the status bar shows the same progress), then continues to the write. The write: an `NSOpenPanel` for a folder (`canChooseDirectories`, prompt "Export"); names `"<take name> - Drums.wav"` …; a per-file overwrite `NSAlert` with Replace / Replace All / Skip / Cancel; conversion `.caf` → 24-bit WAV at the take's `deviceRate` through `AVAudioConverter` off the main thread. |
| Offline engine | `OfflineRenderer` (new, `nonisolated`): builds an `AVAudioEngine`, `enableManualRenderingMode(.offline, format:, maximumFrameCount: 4096)`, an `InstrumentSynthBank(engine:mixTarget:)` of its own, a `NoteScheduler` of its own, and a source node that plays the take's channels (for the two mixes that include the original) through the same crossfade law the live engine uses (`PlaybackEngine.mixGains(mix:)` extracted to Core as a pure function so both use one formula). It applies the sound bank, mixer state and pans, then renders block by block from `start` to `end + tail`, where `tail` ends at the first 4096-frame block whose peak is below −90 dBFS after the last note-off, capped at 2 s. |
| What / Range | `RenderSpec { what: .midi/.mixAsHeard/.original, range: ClosedRange<Double>, format: .wav24/.aiff24/.m4a }`. "As heard" uses the live `mix`, `masterGain`, `stereoSplit`, and the mutes/solos/faders/pans; MIDI only uses mix 1.0 (synth full, original silent) and the master at 0 dB; Original only writes the take's channels clipped to the range, no synth. |
| Writing | `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` with `.wav`/`.aiff` 24-bit integer settings or `kAudioFormatMPEG4AAC` at 256 kb/s; the renderer writes each rendered block. |
| UI | `ExportAudioPanel`: an `NSSavePanel` with a SwiftUI accessory (What / Range / Format), default name `"<take name>.wav"` updated with the format, directory the Music folder as the other exports; defaults in `GlobalSettings.audioExport…`. A progress `NSAlert`-style sheet with Cancel driven by the renderer's `progress` (0…1 by frames) on the main actor; Cancel removes the partial file. |
| Threading | The renderer runs in a `Task.detached`; its engine and synth bank are created and torn down on that task; `renderOffline` is synchronous and polls `Task.isCancelled` every block. The live engine is never touched. |
| Where in the menu | File: … Export MIDI…, Export MusicXML…, Export PDF…, ──, Export Audio… ⌥⌘E, Export Stems… |

## 3. Core

- `MixLaw.swift`: `gains(mix:) -> (original: Float, synth: Float)` extracted from `PlaybackEngine`
  (test: equal power at 0.5, extremes).
- `AudioExportFormat` enum with file extension, `AVAudioFile` settings; `StemNames` (test).
- `GlobalSettings`: `audioExportWhat`, `audioExportFormat` (strings/enums with defaults).

## 4. App

- `Engine/StemSeparator.swift`: `keepTo`. `App/AppModel+Stems.swift`: the folder; the
  separation-only run. `App/AppModel+StemsExport.swift`, `App/AppModel+AudioExport.swift`.
- `Audio/OfflineRenderer.swift` (+ `+Source.swift`): the offline graph; it reuses
  `InstrumentSynthBank` and `NoteScheduler` unchanged (they take an engine and a mix target).
- `UI/Export/ExportAudioPanel.swift`, `UI/Export/RenderProgressSheet.swift`.
- `NeuralSheetApp.swift`: the two menu items.

## 5. Changelog

"Export the separated stems as audio files (File → Export Stems…) and the transcription as it
sounds (File → Export Audio…): the MIDI alone, or the mix as heard."
