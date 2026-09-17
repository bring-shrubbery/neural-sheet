# NeuralSheet v1 — Design

NeuralSheet is a native macOS reimplementation of NeuralNote v2 (C++/JUCE, at
`/Users/antoni/Projects/NeuralNote`, commit `20ca45a`). v1 is a feature-for-feature clone of the
Standalone app. Extra features come later.

The behavioural requirements are the companion document
[`2026-09-17-neuralnote-feature-inventory.md`](2026-09-17-neuralnote-feature-inventory.md)
("the inventory"). Every number, string, colour, path and rule in the inventory is a requirement
unless this spec overrides it (see §7 Deviations) or it is marked **[PLUGIN]**. The inventory is the
parity checklist for the final acceptance pass.

## 1. Goals and non-goals

Goals
- 100 % of the Standalone functionality: record or drop audio, pick instruments, download and pick a
  model, transcribe with streaming notes, play back with mix/master/per-instrument mixer and meters,
  drag or export MIDI, persist settings and session, check for updates.
- Same look: the 1280×800 authored layout, palette, fonts, tracking, icons, metrics, states.
- Lower audio latency and a smoother UI than the JUCE app (native audio graph, display-link driven
  drawing, no full-canvas repaints).

Non-goals for v1
- AU/VST3 plugins, host transport, automatable parameters, MIDI out to a host. Everything tagged
  **[PLUGIN]** in the inventory.
- Note editing, loop playback (the loop button stays present and disabled, as in the original).
- Universal binaries. arm64 only, like the C++ build.

## 2. Decisions already made

| Topic | Decision |
|---|---|
| Transcription engine | Link `muscriptor.cpp` unchanged (git submodule, same commit `0ef3b14e`), through a C bridge |
| Targets | Standalone app only |
| Playback synth | Apple `AVAudioUnitMIDISynth` (built-in GM DLS bank), not TinySoundFont |
| UI | SwiftUI for chrome and controls; AppKit + CoreGraphics for the scrolling timeline |
| Platform | macOS 26.0+, arm64, Xcode 27, Swift 5 language mode, App Sandbox **off**, hardened runtime **on** |
| Repo | `~/Projects/neural-sheet/NeuralSheet`, branch `main`, one commit per task |

## 3. Repository layout

```
NeuralSheet/
  NeuralSheet.xcodeproj            Xcode project (synchronized folders — no pbxproj edits to add files)
  NeuralSheet/                     App target sources (synchronized)
    App/                           @main, window, scene, menu commands, shortcuts
    Engine/                        C bridge to muscriptor.cpp (C++23) + Swift wrapper
    Audio/                         AVAudioEngine graph, recorder, file loading, player, synth, meters
    Decoders/                      stb_vorbis bridge (Ogg Vorbis only; CoreAudio handles the rest)
    UI/                            SwiftUI views, design tokens, icons, AppKit timeline views
    Resources/                     Fonts (Inter, JetBrains Mono NL + licences), app icon
    NeuralSheet-Bridging-Header.h
  Packages/NeuralSheetCore/        Local Swift package: pure logic, `swift test`
  ThirdParty/muscriptor.cpp/       git submodule
  Scripts/build-engine.sh          CMake build of muscriptor.cpp → build/engine/lib/*.a
  docs/superpowers/specs/          this spec, the inventory
  docs/superpowers/plans/          implementation plan
```

The app target gets a **Run Script** build phase (before Compile Sources) that runs
`Scripts/build-engine.sh`, and build settings: `HEADER_SEARCH_PATHS` for the muscriptor include dir,
`LIBRARY_SEARCH_PATHS` for `build/engine/lib`, `OTHER_LDFLAGS` for `-lmuscriptor_ggml -lggml -lggml-base
-lggml-cpu -lggml-metal -lpffft` (the six archives the CMake build produces), and
linked frameworks Metal, Accelerate, Foundation, AVFoundation, AudioToolbox, CoreAudio, CoreMIDI.
`CLANG_CXX_LANGUAGE_STANDARD = c++23`. Bundle id `com.antoni.neuralsheet`, product name
`NeuralSheet`, `NSMicrophoneUsageDescription = "Need access to Microphone"`.

`Scripts/build-engine.sh`: idempotent; configures `ThirdParty/muscriptor.cpp/cpp` with
`-DCMAKE_BUILD_TYPE=Release -DMUSCRIPTOR_METAL=ON -DMUSCRIPTOR_BUILD_TESTS=OFF
-DMUSCRIPTOR_BUILD_BENCH=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64` into
`build/engine`, builds, and copies/links the `.a` files into `build/engine/lib`. Skips work when the
libraries are newer than the submodule tree. Requires CMake on PATH (Homebrew) and network on the first
run (ggml fetch); fails with a clear message otherwise.

## 4. Architecture

Four layers, each depending only on the ones below it.

```
UI (SwiftUI + AppKit timeline)
  ↓ observes
AppModel (@MainActor, Observable) — state machine, session, commands
  ↓ owns
Audio (AVAudioEngine graph)      Engine (Transcriber wrapper)      Downloader / UpdateCheck
  ↓ uses                           ↓ uses
NeuralSheetCore (pure Swift: notes, instruments, manifest, MIDI, peaks, DSP math, settings)
```

### 4.1 NeuralSheetCore (Swift package, unit tested)

| Module file | Responsibility (inventory §) |
|---|---|
| `NoteEvent.swift` | `NoteEvent {start, end, pitch, amplitude, program}`, `isDrum`, sort order, `mergeOverlappingNotesWithSamePitch` (§4) |
| `InstrumentInfo.swift` | The 35-group table: group id, UI name, chip, colour hex, program (`programFor`), `instrumentGroupFor(program)`, fallback `program_<n>` label + HSL hue (§4.1). Group ids and programs copied from `muscriptor.cpp` headers, with a test asserting all 35 ids and colours are distinct |
| `InstrumentMixerState.swift` | Per-program gain/mute/solo, `isAudible`, entries in ascending program order with counts and pitch range, placeholders for selected-but-empty instruments (§4.2, §1.5) |
| `ModelManifest.swift` | Sizes, file names, byte sizes, SHA-256, URL template, part-file naming, "installed" rule, resolution order (§3.1) |
| `ModelDownloader.swift` | URLSession-based, one task per size, Range resume, status-code rules, retry delays 2/5/10 s, verify phase, error strings verbatim, cancel keeps the part (§3.2). Network is injected (`URLProtocol` stub in tests) |
| `MidiFileWriter.swift` | Produces the SMF bytes: format 1, 960 PPQ, conductor track (tempo, 4/4), one track per instrument with name meta + program change, channel map with both overflow modes, velocity 100, tick formula (§6.2). Tests compare against hand-built expected byte sequences |
| `WaveformPeaks.swift` | Min/max pyramid, 64-sample base bins, coarsest-level query rule, raw scan below 2048 samples, `append` for live recording (§2.4) |
| `Resampler.swift` | Downmix by averaging, 4th-order Butterworth low-pass at 8 kHz (biquad cascade designed like JUCE's), Lagrange interpolation to 16 kHz; also generic rate conversion for playback buffers (§2.1). Tests check a 1 kHz sine survives and a 12 kHz sine is attenuated |
| `RmsMeter.swift`, `MeterScale.swift` | 50 ms sliding mean-square, −36…0 dB scale, band thresholds, `lit` count, 24 dB/s release ballistics (§2.5) |
| `PianoRollRange.swift`, `ZoomMath.swift` | Display range rules (whole octaves, widen above first, min 12 semitones, default C0…B5), lane height `6 + norm×37.6`, horizontal zoom clamp, ruler tick divisions with 56 px minimum gap (§7.1, §7.2, §7.4) |
| `TimeFormat.swift` | `mm:ss.dd`, `m:ss`, dB with one decimal, size formatting `x.y GB`/`<n> MB` (§1.3, §3.2) |
| `GlobalSettings.swift` | `modelSize`, `editorScale`, `tooltipsVisible`, `midiOverflowMode`, stored as a property list at `~/Library/NeuralSheet/global.settings`; all keys rewritten on every save (§8.1) |
| `SessionState.swift` | The §8.2 property set (export tempo, overflow mode, source audio path, playhead, centred, zoom, vertical zoom, selected groups, mixer subtree) as JSON at `~/Library/NeuralSheet/session.json`; transcription never saved |
| `AppPaths.swift` | `~/Library/NeuralSheet/{models,recordings}`, `~/Library/NeuralNote/models` as a read-only secondary model location, temp MIDI dir, Music folder |
| `VersionCompare.swift` | Dotted numeric compare, leading v stripped (§9) |
| `AppState.swift` | `enum AppState { empty, recording, audioLoaded, processing, populated }`, `canPlay`, `hasTranscription` (§11.1) |

### 4.2 Engine (app target)

`Engine/nsheet_engine.h` (C, included by the bridging header) and `Engine/nsheet_engine.cpp` (C++23):

```c
typedef struct nsheet_transcriber nsheet_transcriber;
typedef struct { double onset, offset; int pitch, program; bool is_drum; } nsheet_note;
typedef struct { const nsheet_note* new_notes; size_t count; double finalized_through; float progress; } nsheet_update;
typedef bool (*nsheet_progress_fn)(const nsheet_update*, void* ctx);   // return false to cancel

nsheet_transcriber* nsheet_load(const char* gguf_path, bool use_gpu, int* out_error);
const char*         nsheet_backend_name(const nsheet_transcriber*);
int  nsheet_transcribe(nsheet_transcriber*, const float* samples, size_t count,
                       const int32_t* groups, size_t group_count,
                       nsheet_progress_fn cb, void* ctx,
                       nsheet_note** out_notes, size_t* out_count);   // 0 = ok, else nsheet_error
void nsheet_free_notes(nsheet_note*);
void nsheet_free(nsheet_transcriber*);
const char* nsheet_describe_error(int);
int  nsheet_all_groups(int32_t* out, size_t cap);                    // enumerator order
int  nsheet_program_for(int32_t group);
```

Error codes mirror `msl::Error` one-to-one, plus `nsheet_error_unsupported_version` so the UI can
show the "is for another version" message. `Engine/TranscriptionEngine.swift` wraps this in a Swift
class that runs `load + transcribe + free` on one dedicated background thread, stages `new_notes` plus
`finalizedThrough` under a lock, publishes progress atomically, exposes `cancel()`, and always frees
the transcriber before returning (§3.4). The main actor drains it at 30 Hz.

### 4.3 Audio (app target, AVAudioEngine)

Graph:

```
inputNode ──tap──▶ Recorder (native WAV + 16 kHz mono WAV, peaks.append)
sourceNode (AVAudioSourceNode: playhead owner, reads mSourceAudio, schedules MIDI) ─┐
synth[program] (AVAudioUnitMIDISynth, one per instrument, created on demand) ──┐    │
                                                                              ▼    ▼
                                                     instrumentMixer (per-input gain) ─▶ masterMixer ─▶ mainMixer ─▶ output
```

- **Clock**: `sourceNode`'s render block advances the playhead by frames rendered and writes the
  source audio at `playhead − oneBuffer` with `sourceGain`. In the same call it asks `NoteScheduler`
  for the events falling in `[playhead, playhead + buffer)` and schedules them on each instrument's
  `AUScheduleMIDIEventBlock` with sample time `renderTimestamp.sampleTime + buffer + offset`.
  Scheduling one cycle ahead removes the node-ordering ambiguity; delaying the source read by one
  buffer keeps source and synth sample-aligned.
- **NoteScheduler**: port of the C++ scheduler (§5.1): 512 active-note ceiling with oldest stealing,
  30 s lookback on seek/resume/list swap, note-off before note-on at equal offsets, every on matched
  by an off. Drum note-offs are never sent; stop/seek send CC 123 (all notes off) to every synth.
- **Synth setup**: each `AVAudioUnitMIDISynth` receives bank select MSB 121 + program change for
  melodic programs on channel 1, and bank select MSB 120 + program 0 on channel 10 for drums. Voice
  cap left at the AU default. Velocity 100.
- **Mixer**: fader gain in dB → linear on the instrument's mixer input (`−36 dB` = 0), mute/solo via
  `isAudible` per block, master gain −36…+6 dB, mix crossfade `cos/sin(mix·π/2)`; mix forced to 0 when
  there are no notes (§5.3). A tap on each instrument input feeds its `RmsMeter`; a tap after the
  master mixer feeds the master meter. Meters publish once per buffer; the UI reads them on the display
  link with the staleness rule.
- **Recorder** (§2.1): input tap → `AVAudioFile` at native rate 16-bit; the same buffer goes through
  `Resampler` to the 16 kHz mono `AVAudioFile`; peaks appended from the downsampled stream. On stop
  both files are read back so playback uses the 16-bit round-tripped audio. Zero samples → clear.
- **File loading** (§2.2): `AVAudioFile` decodes wav/aiff/flac/mp3; `.ogg` goes through the bridged
  `stb_vorbis` (public domain, copied from the C++ repo's TinySoundFont folder). Then `Resampler` →
  16 kHz mono for the model and → device rate for playback. Device-rate change re-resamples.
- **Latency**: engine I/O buffer requested at 128 frames (`AVAudioSession` equivalent on macOS:
  `kAudioDevicePropertyBufferFrameSize` via the output unit); input monitoring is not a feature
  (NeuralNote passes input through in plugin mode only), so the standalone does **not** route input to
  output.

### 4.4 AppModel (main actor)

One `@Observable` class owning: `AppState`, `SourceAudio` (buffers, duration, dropped file name,
recording paths), `Transcription` (raw notes, post-processed notes, `finalizedThrough`, progress,
cancel latch), `InstrumentSelection`, `InstrumentMixerState`, `Transport` (playing, playhead,
follow-playhead, mute), `Zoom` (horizontal, vertical or auto), model choice and download states,
update-check state. It exposes the commands the UI calls (record, load, transcribe, cancel, play,
seek, clear, clearTranscription, exportMidi, dragMidi, setModel…) and enforces the state rules in
inventory §11.1 and §3.4 (≥ 1 s of audio, mixer reset on launch, replace streamed notes with the
authoritative result). It saves `SessionState` on quit and restores it on launch, re-reading the
source audio from its path.

Timers match the inventory: 30 Hz engine drain, 10 Hz model panel poll, 5 Hz update-notice tick,
display link for playhead/meters/time display/progress pulse.

### 4.5 UI

- **Scale**: the window content is the 1280×800 authored canvas. `NSWindow` gets
  `contentAspectRatio = 1280:800`, min 640×400, max = min(2560×1600, display rule in §1.1). The applied
  scale `min(w/1280, h/800)` is injected as `@Environment(\.uiScale)` and every metric goes through
  `s(_:)`; fonts use `pointSize × scale`. Persisted as `editorScale` on close. Settings menu presets
  50/75/100/125/150/200 %.
- **Design tokens**: `UI/Theme.swift` with every colour from §1.8, `UI/Fonts.swift` registering the
  bundled TTFs and exposing the §1.10 accessors, tracking via `.kerning(em × pointSize)`.
- **Icons**: `UI/Icons.swift`, each icon a SwiftUI `Shape` ported from the C++ `Path` code, 1.3 pt
  stroke, round caps/joins.
- **Views** (one file each, metrics from §1): `TopBar`, `TimeDisplay`, `Sidebar`, `InstrumentStrip`,
  `MasterPanel`, `LevelMeter`, `Toolbar`, `TempoField`, `StatusBar`, `TranscriptionProgress`,
  `ModelPanel`, `InstrumentMenu`, `SettingsMenu`, `UpdateNotice`, `TooltipModifier` (800 ms delay,
  260 pt max width, popup surface), `EmptyWaveformState` (drop zone + Load button), `TranscribeCTA`.
  Hover/press/disabled follow §1.9 exactly (0.38 disabled alpha, 0.5 muted alpha).
- **Timeline** (`UI/Timeline/`): `TimelineView` is an `NSViewRepresentable` around an `NSScrollView`
  (horizontal only, custom thin scroller colours) whose document view stacks three `NSView`s —
  `WaveformView` (126 pt), `RulerView` (22 pt), `PianoRollView` — all sharing one `TimelineGeometry`
  (px per second, scroll origin, pitch range, lane height). Each draws only `dirtyRect`. The gutter and
  `KeyboardView` sit outside the scroll view. A `PlayheadLayer` (CALayer) per view is repositioned from
  a `CADisplayLink`-equivalent (`NSView.displayLink`) without redrawing. Wheel/pinch/⌘-wheel rules,
  follow-playhead centring, auto-scroll while recording, click-to-seek, frontier shading and the
  Transcribe CTA overlay per §7. Drag-and-drop of audio files onto the waveform area.
- **MIDI out**: the Drag button uses `.onDrag` with an `NSItemProvider` file URL written to
  `<temp>/neuralsheet/<name>.mid`; the temp directory is removed on quit. Export uses `NSSavePanel`
  titled "Export MIDI", Music folder, `.mid`, same names as §6.1.
- **Shortcuts**: §11.2 via SwiftUI `.keyboardShortcut` on hidden commands plus an `NSEvent` local
  monitor for Space/Shift-Space/r/m/c/Esc so they work regardless of focus.
- **Dialogs**: `NSAlert` with the §11.7 titles and bodies.

## 5. Data flow (one transcription)

1. User drops a file → `AppModel.load(url)` → `clear()` → decode → resample (both rates) → peaks →
   state `audioLoaded` → session saved.
2. User ticks instruments → placeholders appear in the sidebar; `SessionState.selectedGroups` updated.
3. Transcribe → `AppModel.launchTranscribe()` applies §3.4 steps 1–9 → `TranscriptionEngine.run(...)`
   on its thread.
4. Every chunk: engine stages notes; the 30 Hz drain merges them into `rawNotes`, recomputes
   `postProcessedNotes`, updates `finalizedThrough`, hands a copy to `NoteScheduler.swap(notes)`,
   widens the piano-roll range, repaints the roll.
5. Playback during processing plays source + synth up to `finalizedThrough`.
6. Completion: streamed list replaced by the authoritative result, `finalizedThrough = duration`,
   state `populated`, export buttons enabled.
7. Drag/export writes the MIDI via `MidiFileWriter` with the toolbar tempo and the settings overflow
   mode.

## 6. Error handling

- Engine load/run errors surface as the §3.4 dialog; cancel returns to `audioLoaded`.
- Downloader errors are the §3.2 strings, shown in the model row; retryable ones retry with backoff.
- Audio file errors show the §11.7 dialogs; the unsupported-extension case lists the accepted
  extensions.
- Recording failures show the §2.1 dialogs. All alerts are non-blocking (`beginSheetModal` or
  `runModal` on the main actor after the failing operation has cleaned up).
- The audio render block never allocates or locks: note lists are swapped by pointer, MIDI event
  buffers are pre-sized (4×512), meters use fixed ring buffers.

## 7. Deviations from the original (accepted)

1. Synth timbre: Apple's GM DLS bank instead of MuseScore General. Note-off policy for drums kept.
2. Standalone only; **[PLUGIN]** items dropped. Mute button mutes the app's own output.
3. Paths under `~/Library/NeuralSheet/`; models are also discovered read-only in
   `~/Library/NeuralNote/models` so they are not downloaded twice.
4. Update check targets `https://api.github.com/repos/antoni/neural-sheet/releases/latest` and the
   matching releases page (placeholder until a repo exists); notice text says "NeuralSheet".
5. Global settings and session state are property-list/JSON files instead of JUCE XML, no
   inter-process locks (single app).
6. Product name NeuralSheet, wordmark "NEURALSHEET" with the same "v2"-style version tag showing the
   app's version ("v1").
7. No JUCE "Options" button or audio-settings dialog. Instead a minimal Audio menu in the menu bar
   listing input and output devices (needed because the standalone must let you pick the mic).

## 8. Testing

- `swift test` in `Packages/NeuralSheetCore` for everything in §4.1 (TDD, written before the
  implementation in each task).
- App target: an XCTest bundle is not added (pbxproj target surgery is not worth it); the engine
  bridge gets a `Scripts/engine-smoke.sh` that builds a tiny CLI against the bridge and transcribes
  1 s of silence with the small model when one is installed.
- Every task ends with `xcodebuild -scheme NeuralSheet -configuration Debug build` succeeding with
  zero warnings in our own code.
- Final parity pass: an Opus agent walks the inventory section by section against the Swift sources
  and the running app (screenshots via the `run` skill) and files a gap list; gaps become follow-up
  tasks before v1 is called done.

## 9. Implementation phases

1. **Scaffold**: project settings, .gitignore, fonts, Core package skeleton, submodule, build script,
   C bridge, engine smoke test.
2. **Core package**: the §4.1 modules, each an independent task with tests (parallel agents).
3. **Audio**: graph, recorder, loader, scheduler, synth, meters (two or three tasks, sequential
   where they share the engine class).
4. **UI + integration**: theme/fonts/icons first, then each view as a task, timeline as its own task,
   then AppModel wiring, persistence, MIDI out, shortcuts, dialogs.
5. **Parity pass** and fixes.

Each task: one commit on `main`, message `<area>: <what>`, with the Claude co-author trailer.
