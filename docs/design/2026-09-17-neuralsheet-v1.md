# NeuralSheet v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS (SwiftUI + AVAudioEngine) clone of the NeuralNote v2 Standalone app with 100 % of its functionality, linking the original `muscriptor.cpp` engine.

**Architecture:** Four layers: `NeuralSheetCore` (pure Swift package, unit-tested) ← Audio graph / Engine bridge / Downloader ← `AppModel` (main-actor state machine) ← UI (SwiftUI chrome, AppKit timeline). The C++ engine is built by CMake from a git submodule and linked as static libraries through a C bridge.

**Tech Stack:** Swift 5 mode on Xcode 27, SwiftUI, AppKit, AVFoundation (`AVAudioEngine`, `AVAudioSourceNode`, `AVAudioUnitMIDISynth`, `AVAudioFile`), Accelerate, CryptoKit, URLSession, Swift Testing (`import Testing`) in the package, CMake for `muscriptor.cpp`, stb_vorbis (C) for Ogg.

**Spec:** `docs/superpowers/specs/2026-09-17-neuralsheet-design.md` (the design) and `docs/superpowers/specs/2026-09-17-neuralnote-feature-inventory.md` (the inventory: every exact number, string, colour and rule). **Read both before starting any task.** Where this plan says "per inventory §N", the executor copies the values from that section verbatim.

## Global Constraints

- Repo: `/Users/antoni/Projects/neural-sheet/NeuralSheet`, branch `main`, one commit per task, message `<area>: <what>`, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Reference C++ sources: `/Users/antoni/Projects/NeuralNote` (read-only; consult when the inventory is not enough).
- Platform: macOS 26.0 deployment target, arm64 only, Xcode 27, Swift language mode 5, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, App Sandbox OFF, Hardened Runtime ON.
- Product name `NeuralSheet`, bundle id `com.quassum.neuralsheet`, wordmark text `NEURALSHEET`, version tag `v1`.
- File paths: `~/Library/NeuralSheet/models`, `~/Library/NeuralSheet/recordings`, `~/Library/NeuralSheet/global.settings`, `~/Library/NeuralSheet/session.json`; secondary read-only models dir `~/Library/NeuralNote/models`; MIDI drag scratch `<NSTemporaryDirectory>/neuralsheet/`.
- Every colour, metric, font, string and threshold comes from the inventory. Do not invent values. Do not use SF Symbols where the inventory has a code-built icon.
- Adding a Swift/C/C++ file under `NeuralSheet/` is enough to include it in the app target (synchronized folder). Never edit `project.pbxproj` except where a task says so.
- App-target verification command (must succeed with no warnings in our own files):
  `xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20`
- Package verification: `cd Packages/NeuralSheetCore && swift test 2>&1 | tail -20`.
- The audio render path (anything called from an `AVAudioSourceNode` render block or an audio tap) must not allocate, lock, or touch Swift classes that can be resized; use pre-sized buffers and `os_unfair_lock`-free designs (atomics / pointer swaps).
- Tests are written before the implementation in every Core task (TDD).

---

## File map

```
NeuralSheet/
  App/NeuralSheetApp.swift                 @main App, WindowGroup, commands, font registration
  App/MainWindow.swift                     NSWindow aspect lock, min/max size, scale persistence
  App/AppModel.swift                       @MainActor @Observable model (Task 14)
  App/AppModel+Transcription.swift         launch/cancel/drain (Task 14)
  App/AppModel+Session.swift               session save/restore (Task 20)
  App/KeyboardShortcuts.swift              NSEvent monitor (Task 20)
  App/Dialogs.swift                        NSAlert helpers with inventory strings (Task 20)
  App/UpdateCheck.swift                    GitHub release check (Task 20)
  Engine/nsheet_engine.h / .cpp            C bridge (Task 2)
  Engine/TranscriptionEngine.swift         Swift wrapper, background thread (Task 2)
  Decoders/stb_vorbis.c, stb_vorbis.h, OggDecoder.swift   (Task 10)
  Audio/AudioDevices.swift                 input/output device listing & selection (Task 10)
  Audio/SourceAudio.swift                  loaded audio buffers (device-rate + 16 kHz mono) (Task 10)
  Audio/AudioFileLoader.swift              AVAudioFile + Ogg → SourceAudio (Task 10)
  Audio/PlaybackEngine.swift               AVAudioEngine graph, source node, playhead, mix, master (Task 10)
  Audio/Recorder.swift                     input tap → two WAVs (Task 11)
  Audio/NoteScheduler.swift                port of the C++ scheduler (Task 12)
  Audio/InstrumentSynthBank.swift          AVAudioUnitMIDISynth per program + mixer inputs + meters (Task 12)
  UI/Theme.swift                           colours (Task 13)
  UI/Fonts.swift                           font accessors + tracking (Task 13)
  UI/Icons.swift                           Shapes (Task 13)
  UI/Scale.swift                           uiScale environment + s() (Task 13)
  UI/Controls/FlatButton.swift, PillSlider.swift, PopupSurface.swift, TooltipModifier.swift, MenuPanel.swift (Task 13)
  UI/TopBar/TopBar.swift, TimeDisplay.swift             (Task 15)
  UI/Sidebar/Sidebar.swift, InstrumentStrip.swift, MasterPanel.swift, LevelMeter.swift, InstrumentMenu.swift (Task 16)
  UI/Toolbar/Toolbar.swift, TempoField.swift            (Task 17)
  UI/StatusBar/StatusBar.swift, TranscriptionProgress.swift (Task 17)
  UI/ModelPanel/ModelPanel.swift                        (Task 18)
  UI/Timeline/TimelineGeometry.swift, TimelineView.swift, WaveformView.swift, RulerView.swift,
     PianoRollView.swift, KeyboardView.swift, GutterView.swift, PlayheadLayer.swift,
     EmptyWaveformOverlay.swift, TranscribeCTA.swift    (Task 19)
  UI/MainView.swift                        1280×800 composition (Task 20)
  UI/SettingsMenu.swift, UI/UpdateNotice.swift          (Task 20)
  Resources/Fonts/*.ttf + licences         (Task 1)
Packages/NeuralSheetCore/
  Package.swift
  Sources/NeuralSheetCore/{AppState,NoteEvent,TimeFormat,InstrumentInfo,InstrumentMixerState,
     ModelManifest,AppPaths,ModelDownloader,MidiFileWriter,WaveformPeaks,Resampler,
     RmsMeter,MeterScale,PianoRollRange,ZoomMath,RulerTicks,GlobalSettings,SessionState,VersionCompare}.swift
  Tests/NeuralSheetCoreTests/<same names>Tests.swift
Scripts/build-engine.sh, Scripts/engine-smoke.sh, Scripts/engine_smoke.cpp
ThirdParty/muscriptor.cpp                  submodule
```

## Task dependency graph

```
T1 scaffold ─▶ T2 engine ─┐
T1 ─▶ T3,T4,T5,T7 (parallel) ─▶ T6,T8,T9 (parallel) ─▶ T10 ─▶ T11, T12 (parallel)
T1 ─▶ T13 (parallel with T3..T12)
T12 + T13 + T2 ─▶ T14 ─▶ T15,T16,T17,T18,T19 (parallel) ─▶ T20 ─▶ T21
```

---

### Task 1: Project scaffold, Core package, fonts

**Files:**
- Modify: `NeuralSheet.xcodeproj/project.pbxproj` (build settings + local package reference only)
- Delete: `NeuralSheet/MyApp.swift`, `NeuralSheet/ContentView.swift`
- Create: `NeuralSheet/App/NeuralSheetApp.swift`, `NeuralSheet/UI/MainView.swift` (placeholder text "NeuralSheet"), `NeuralSheet/Resources/Fonts/*` (copied), `Packages/NeuralSheetCore/Package.swift`, `Packages/NeuralSheetCore/Sources/NeuralSheetCore/AppState.swift`, `Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/AppStateTests.swift`

**Interfaces:**
- Produces: `public enum AppState: String, Codable, Sendable { case empty, recording, audioLoaded, processing, populated; public var canPlay: Bool; public var hasTranscription: Bool }` (inventory §11.1: canPlay = audioLoaded|processing|populated; hasTranscription = processing|populated). `NeuralSheetCore` importable from the app.

- [ ] **Step 1: Project settings.** In `project.pbxproj`, for both configurations of the app target and project: `SUPPORTED_PLATFORMS = macosx`, `SDKROOT = macosx`, remove `TARGETED_DEVICE_FAMILY` and any iOS/visionOS keys, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `PRODUCT_BUNDLE_IDENTIFIER = com.quassum.neuralsheet`, `ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`, `INFOPLIST_KEY_NSMicrophoneUsageDescription = "Need access to Microphone"`, `MARKETING_VERSION = 1.0.0`, `CLANG_CXX_LANGUAGE_STANDARD = "c++23"`, `SWIFT_OBJC_BRIDGING_HEADER = "NeuralSheet/NeuralSheet-Bridging-Header.h"`, `ARCHS = arm64`. Remove the `Playgrounds` import and the `#Playground` block by deleting `ContentView.swift`.
- [ ] **Step 2: App entry.** `App/NeuralSheetApp.swift`: `@main struct NeuralSheetApp: App` with a single `Window("NeuralSheet", id: "main") { MainView() }` (not `WindowGroup`, one window only), `.windowResizability(.contentSize)` left off (Task 20 handles sizing). Call `FontRegistry.registerBundledFonts()` from `init()` — for now define `enum FontRegistry { static func registerBundledFonts() }` in `UI/Fonts.swift` that enumerates `Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)` and calls `CTFontManagerRegisterFontsForURL(url, .process, nil)`. Create an empty `NeuralSheet/NeuralSheet-Bridging-Header.h`.
- [ ] **Step 3: Fonts.** Copy the 7 TTFs and 2 licence files from `/Users/antoni/Projects/NeuralNote/NeuralNote/Assets/Fonts/` into `NeuralSheet/Resources/Fonts/`. Confirm they land in the built app's `Contents/Resources` (synchronized folder copies non-source files as resources).
- [ ] **Step 4: Core package.** `Packages/NeuralSheetCore/Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NeuralSheetCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "NeuralSheetCore", targets: ["NeuralSheetCore"])],
    targets: [
        .target(name: "NeuralSheetCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NeuralSheetCoreTests", dependencies: ["NeuralSheetCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
```
- [ ] **Step 5: Failing test.** `AppStateTests.swift` using Swift Testing: `@Test func canPlayStates()` asserting `AppState.audioLoaded.canPlay`, `.processing.canPlay`, `.populated.canPlay` are true and `.empty`, `.recording` false; `@Test func hasTranscriptionStates()` true only for processing/populated. Run `swift test` → compile failure (type missing).
- [ ] **Step 6: Implement `AppState.swift`**, run `swift test` → pass.
- [ ] **Step 7: Link the package to the app.** Add an `XCLocalSwiftPackageReference` with `relativePath = Packages/NeuralSheetCore` to the project, an `XCSwiftPackageProductDependency` (productName `NeuralSheetCore`) to the app target's `packageProductDependencies`, and a `PBXBuildFile` for it in the Frameworks build phase. Then `import NeuralSheetCore` in `MainView.swift` and reference `AppState.empty.canPlay` in a `let` so the link is exercised.
- [ ] **Step 8: Verify** with the xcodebuild command (Global Constraints). Launch once: `open build/Debug/NeuralSheet.app` or via `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR`; window must appear. Quit it.
- [ ] **Step 9: Commit** `scaffold: macOS-only project, Core package, bundled fonts`.

---

### Task 2: Engine submodule, CMake build script, C bridge, Swift wrapper, smoke test

**Files:**
- Create: `.gitmodules` + `ThirdParty/muscriptor.cpp` (submodule `https://github.com/DamRsn/muscriptor.cpp.git` at commit `0ef3b14e6e39e7296a0a0202ad07b41de3e99649`), `Scripts/build-engine.sh`, `Scripts/engine_smoke.cpp`, `Scripts/engine-smoke.sh`, `NeuralSheet/Engine/nsheet_engine.h`, `NeuralSheet/Engine/nsheet_engine.cpp`, `NeuralSheet/Engine/TranscriptionEngine.swift`
- Modify: `NeuralSheet/NeuralSheet-Bridging-Header.h` (add `#include "Engine/nsheet_engine.h"`), `project.pbxproj` (run-script phase, header/library search paths, linker flags, frameworks)

**Interfaces:**
- Consumes: `muscriptor/muscriptor.hpp` (inventory appendix "muscriptor.cpp — public API").
- Produces (C, see spec §4.2 for the full header):
```c
typedef struct nsheet_transcriber nsheet_transcriber;
typedef struct { double onset, offset; int32_t pitch, program; bool is_drum; } nsheet_note;
typedef struct { const nsheet_note* new_notes; size_t count; double finalized_through; float progress; } nsheet_update;
typedef bool (*nsheet_progress_fn)(const nsheet_update* update, void* ctx);
enum nsheet_error { NSHEET_OK = 0, NSHEET_ERR_FILE_NOT_FOUND, NSHEET_ERR_INVALID_CHECKPOINT, NSHEET_ERR_UNSUPPORTED_ARCH,
  NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION, NSHEET_ERR_OUT_OF_MEMORY, NSHEET_ERR_CONTEXT_OVERFLOW, NSHEET_ERR_CANCELLED,
  NSHEET_ERR_INVALID_ARGUMENT, NSHEET_ERR_INTERNAL };
nsheet_transcriber* nsheet_load(const char* gguf_path, bool use_gpu, int* out_error);
const char* nsheet_backend_name(const nsheet_transcriber*);
int nsheet_transcribe(nsheet_transcriber*, const float* samples, size_t count, const int32_t* groups, size_t group_count,
                      nsheet_progress_fn cb, void* ctx, nsheet_note** out_notes, size_t* out_count);
void nsheet_free_notes(nsheet_note*);
void nsheet_free(nsheet_transcriber*);
const char* nsheet_describe_error(int);
size_t nsheet_all_groups(int32_t* out, size_t cap);   // returns count written (35), enumerator order
int32_t nsheet_program_for(int32_t group);
```
- Produces (Swift):
```swift
struct EngineNote { var onset: Double; var offset: Double; var pitch: Int; var program: Int; var isDrum: Bool }
struct EngineUpdate { var newNotes: [EngineNote]; var finalizedThrough: Double; var progress: Float }
enum EngineError: Error { case load(code: Int32, message: String), transcribe(code: Int32, message: String), cancelled
    var isUnsupportedVersion: Bool }
final class TranscriptionEngine {
    /// Runs load → transcribe → free on a dedicated thread. `onUpdate` is called on that thread; return false to cancel.
    /// `completion` is called on that thread with the authoritative result. The model is always freed before completion.
    func run(modelPath: URL, groups: [Int32], samples16k: [Float],
             onUpdate: @escaping (EngineUpdate) -> Bool,
             completion: @escaping (Result<[EngineNote], EngineError>) -> Void)
    func cancel()                       // sets an atomic flag observed at the next chunk callback
    var isRunning: Bool { get }
    static func allGroups() -> [Int32]
    static func program(for group: Int32) -> Int32
}
```

- [ ] **Step 1: Submodule.** `git submodule add https://github.com/DamRsn/muscriptor.cpp.git ThirdParty/muscriptor.cpp && cd ThirdParty/muscriptor.cpp && git checkout 0ef3b14e6e39e7296a0a0202ad07b41de3e99649`.
- [ ] **Step 2: Build script** `Scripts/build-engine.sh` (bash, `set -euo pipefail`): `ROOT=$(cd "$(dirname "$0")/.." && pwd)`; `OUT=$ROOT/build/engine`; if `$OUT/lib/libmuscriptor_ggml.a` exists and is newer than `$ROOT/ThirdParty/muscriptor.cpp/cpp/CMakeLists.txt` and `$OUT/.stamp`, exit 0. Require `cmake` on PATH (also check `/opt/homebrew/bin/cmake`; Xcode run-script PATH lacks Homebrew) else `echo "error: cmake not found; brew install cmake" >&2; exit 1`. Configure with the flags in spec §3 (`-DCMAKE_BUILD_TYPE=Release -DMUSCRIPTOR_METAL=ON -DMUSCRIPTOR_BUILD_TESTS=OFF -DMUSCRIPTOR_BUILD_BENCH=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_TESTING=OFF`), `cmake --build "$OUT" -j"$(sysctl -n hw.ncpu)"`, then `mkdir -p $OUT/lib` and copy the six archives (`libmuscriptor_ggml.a`, `libpffft.a`, `_deps/ggml-build/src/libggml.a`, `libggml-base.a`, `libggml-cpu.a`, `ggml-metal/libggml-metal.a`) into it (use `find "$OUT" -name '*.a'` to locate them), `touch $OUT/.stamp`. Run it once by hand; it must succeed (network needed for the ggml fetch).
- [ ] **Step 3: C bridge.** Implement `nsheet_engine.h`/`.cpp` per the interface above. `nsheet_load` calls `msl::Transcriber::load(path, {.use_gpu = use_gpu})`; on error writes the mapped code and returns null. `nsheet_transcribe` builds `TranscribeOptions{instruments = groups}`, wraps `cb` in a `NoteCallback` that copies `new_notes` into a `std::vector<nsheet_note>` for the duration of the call, and on success `malloc`s the result array. Map every `msl::Error` enumerator 1:1 to `nsheet_error`. `nsheet_describe_error` returns `msl::describe`. Install `msl::setLogCallback` once (Warn level) forwarding to `fprintf(stderr, ...)`.
- [ ] **Step 4: Xcode wiring.** In `project.pbxproj` add to the app target: a `PBXShellScriptBuildPhase` named "Build engine" **before** "Sources" running `"$SRCROOT/Scripts/build-engine.sh"` with `alwaysOutOfDate = 1`; build settings `HEADER_SEARCH_PATHS = "$(SRCROOT)/ThirdParty/muscriptor.cpp/cpp/include"`, `LIBRARY_SEARCH_PATHS = "$(SRCROOT)/build/engine/lib"`, `OTHER_LDFLAGS = "-lmuscriptor_ggml -lggml -lggml-base -lggml-cpu -lggml-metal -lpffft -framework Metal -framework Accelerate -framework Foundation -framework MetalKit"`. Add `#include "Engine/nsheet_engine.h"` to the bridging header (the header must be pure C: guard with `extern "C"` for C++).
- [ ] **Step 5: Swift wrapper** `TranscriptionEngine.swift` per the interface: a `Thread` with `qualityOfService = .userInitiated` and name "NeuralSheet.Transcription"; the C callback trampoline uses `Unmanaged.passUnretained(self).toOpaque()` as `ctx`, converts `nsheet_update` to `EngineUpdate`, calls `onUpdate`, and returns `onUpdate(...) && !cancelRequested` (atomic `ManagedAtomic<Bool>`-free: use `os_unfair_lock`-guarded Bool or `Atomics`-less `NSLock`; this is not the audio thread). `EngineError.isUnsupportedVersion` is `code == NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION`.
- [ ] **Step 6: Smoke test.** `Scripts/engine_smoke.cpp`: `main(argc, argv)` loads `argv[1]`, transcribes 2 s of a 440 Hz sine at 16 kHz (32 000 samples) with no groups and a callback that prints `progress` and `count`, prints the note count and the backend name, returns 0 on success. `Scripts/engine-smoke.sh` compiles it with `clang++ -std=c++23 -I ThirdParty/muscriptor.cpp/cpp/include NeuralSheet/Engine/nsheet_engine.cpp Scripts/engine_smoke.cpp -L build/engine/lib <the six -l flags> -framework Metal -framework MetalKit -framework Accelerate -framework Foundation -o build/engine/smoke` and runs it with the first of `~/Library/NeuralSheet/models/muscriptor-small-f16.gguf`, `~/Library/NeuralNote/models/muscriptor-small-f16.gguf`, `…/muscriptor-large-f16.gguf` that exists (the large one is installed on this machine). Expected: prints `backend: Metal` and a note count ≥ 1.
- [ ] **Step 7: Verify** the xcodebuild command builds the app (engine phase runs, links). Run `Scripts/engine-smoke.sh`; it must exit 0.
- [ ] **Step 8: Commit** `engine: muscriptor.cpp submodule, CMake build phase, C bridge and Swift wrapper` (include `.gitmodules`; do not commit `build/`).

---

### Task 3: NoteEvent, merge, TimeFormat

**Files:**
- Create: `Sources/NeuralSheetCore/NoteEvent.swift`, `TimeFormat.swift`; Tests: `NoteEventTests.swift`, `TimeFormatTests.swift` (paths under `Packages/NeuralSheetCore/`).

**Interfaces (Produces):**
```swift
public struct NoteEvent: Equatable, Hashable, Codable, Sendable {
    public var startTime: Double, endTime: Double, pitch: Int, amplitude: Double, program: Int
    public static let drumProgram = 128
    public static let defaultAmplitude = 100.0 / 127.0
    public var isDrum: Bool { program == NoteEvent.drumProgram }
    public init(startTime: Double, endTime: Double, pitch: Int, amplitude: Double = NoteEvent.defaultAmplitude, program: Int)
}
extension NoteEvent: Comparable { /* (startTime, program, pitch, endTime) */ }
public func mergeOverlappingNotesWithSamePitch(_ notes: [NoteEvent]) -> [NoteEvent]   // sorted output
public enum TimeFormat {
    public static func transport(_ seconds: Double) -> String      // "mm:ss.dd"
    public static let transportPlaceholder = "--:--.--"
    public static func ruler(_ seconds: Double) -> String          // "m:ss"
    public static func decibels(_ db: Double) -> String            // one decimal, e.g. "-3.0"
    public static func seconds2(_ s: Double) -> String             // "dd.dd s" body for the status bar: "12.34"
    public static func fileSize(bytes: Int64) -> String            // "2.7 GB" / "618 MB" per inventory §3.2
    public static func pitchName(_ midi: Int) -> String            // "C2", "G#5" — octave = midi/12 - 1
}
```
- [ ] **Step 1: Tests.** `NoteEventTests`: sort order is (start, program, pitch, end); `isDrum` for 128; merge joins `[0,1]` and `[0.5,2]` same pitch+program into `[0,2]`; merge keeps two instruments on one pitch separate; merge does not join non-overlapping notes; merge keeps later end when the second note ends earlier; output sorted. `TimeFormatTests`: `transport(61.239) == "01:01.23"`, `ruler(65) == "1:05"`, `decibels(-3) == "-3.0"`, `fileSize(618_442_496) == "618 MB"`, `fileSize(2_739_142_176) == "2.7 GB"`, `pitchName(60) == "C4"`, `pitchName(36) == "C2"`, `pitchName(79) == "G5"`.
- [ ] **Step 2:** run → fail. **Step 3:** implement. **Step 4:** run → pass.
- [ ] **Step 5: Commit** `core: NoteEvent, overlap merge and time formatting`.

---

### Task 4: InstrumentInfo and InstrumentMixerState

**Files:** Create `InstrumentInfo.swift`, `InstrumentMixerState.swift`, tests `InstrumentInfoTests.swift`, `InstrumentMixerStateTests.swift`.

**Interfaces (Produces):**
```swift
public struct RGBA: Equatable, Hashable, Codable, Sendable { public var r, g, b, a: Double; public init(hex: UInt32, alpha: Double = 1); public static func hsl(h: Double, s: Double, l: Double) -> RGBA }
public enum InstrumentGroup: Int32, CaseIterable, Codable, Sendable { /* the 35 cases with the exact raw ids from inventory §4.1 / appendix; allCases in enumerator (numeric) order */ }
public struct InstrumentInfo: Sendable { public let group: InstrumentGroup?; public let program: Int; public let name: String; public let abbreviation: String; public let colour: RGBA }
public enum Instruments {
    public static let all: [InstrumentInfo]                     // 35, in InstrumentGroup enumerator order
    public static func program(for group: InstrumentGroup) -> Int   // copied from muscriptor's programFor table (see cpp/src/instrument_groups.inc)
    public static func group(forProgram p: Int) -> InstrumentGroup?
    public static func info(forProgram p: Int) -> InstrumentInfo  // fallback: name "program_<p>", abbreviation "\(p)", colour hsl(p%128/128, 0.22, 0.62)
}
public struct InstrumentEntry: Equatable, Sendable { public var program: Int; public var info: InstrumentInfo; public var noteCount: Int; public var lowestPitch: Int; public var highestPitch: Int; public var isPlaceholder: Bool { noteCount == 0 } }
public struct InstrumentChannelSettings: Equatable, Codable, Sendable { public var gainDb: Double = 0; public var muted = false; public var soloed = false }
public struct InstrumentMixerState: Equatable, Codable, Sendable {
    public static let minGainDb = -36.0, maxGainDb = 6.0, gainStepDb = 0.1
    public var settings: [Int: InstrumentChannelSettings]          // keyed by program; absent = defaults
    public private(set) var entries: [InstrumentEntry]            // ascending program
    public mutating func update(notes: [NoteEvent], selectedPrograms: [Int])   // rebuild entries: counts from notes, placeholders for selected programs without notes
    public func isAudible(program: Int) -> Bool                    // !muted && (no soloed among entries || soloed)
    public mutating func setGain(program: Int, db: Double); setMuted(program:muted:); setSoloed(program:soloed:)
    public mutating func resetStoredSettings()
    public var anySoloed: Bool
}
```
- [ ] **Step 1: Tests.** All 35 group raw values distinct and equal to the inventory table; all 35 colours distinct; `Instruments.all.count == 35`; `info(forProgram:)` for a group's program returns its name; `program(for:)` returns muscriptor's own table value for each group (read `ThirdParty/muscriptor.cpp/cpp/src/instrument_groups.inc` in the NeuralNote checkout and copy it; assert a few concrete values in the test with a comment citing the line). Note that `NoteEvent.program` for drums is 128 regardless of what the table says for `Drums`, because the engine rewrites drum programs to 128 (inventory §4). Mixer: entries ascending by program with drums last; placeholders for selected programs; `isAudible` solo semantics; `resetStoredSettings` empties `settings`; gain clamps to [−36, 6].
- [ ] **Step 2–4:** fail → implement → pass. Colour hex values, names, chips: inventory §4.1 verbatim.
- [ ] **Step 5: Commit** `core: instrument table and mixer state`.

---

### Task 5: ModelManifest, AppPaths, ModelDownloader

**Files:** Create `ModelManifest.swift`, `AppPaths.swift`, `ModelDownloader.swift`; tests `ModelManifestTests.swift`, `ModelDownloaderTests.swift` (with a `StubURLProtocol`).

**Interfaces (Produces):**
```swift
public enum ModelSize: String, CaseIterable, Codable, Sendable { case small, medium, large; public var displayName: String /* "Small" */; public var hint: String /* "Fastest" | "Recommended" | "Largest, slowest" */ }
public struct ModelSpec: Sendable { public let size: ModelSize; public let fileName: String; public let byteSize: Int64; public let sha256Hex: String; public var url: URL; public var partFileName: String /* "<fileName>.<first 8 hex>.part" */ }
public enum ModelManifest { public static let revision: String; public static func spec(for: ModelSize) -> ModelSpec; public static let all: [ModelSpec] }
public struct AppPaths: Sendable {
    public var root: URL            // ~/Library/NeuralSheet
    public var models: URL, recordings: URL, globalSettings: URL, session: URL
    public var secondaryModels: URL // ~/Library/NeuralNote/models (read-only)
    public var midiScratch: URL     // NSTemporaryDirectory()/neuralsheet
    public var musicFolder: URL
    public static let standard: AppPaths
    public init(root: URL, secondaryModels: URL, temp: URL, music: URL)
    public func ensureDirectories() throws
}
public struct ModelStore {   // "installed" = exists with exactly byteSize; searches models then secondaryModels
    public init(paths: AppPaths)
    public func installedPath(for: ModelSize) -> URL?
    public func installed() -> Set<ModelSize>
    public func resolve(preferred: ModelSize?) -> ModelSize?        // preferred → .medium → first installed → nil
    public func deleteStalePartFiles()                               // part files with other digests
}
public enum DownloadPhase: Equatable, Sendable { case idle, downloading(received: Int64, total: Int64), verifying, failed(message: String) }
public final class ModelDownloader: @unchecked Sendable {
    public init(paths: AppPaths, session: URLSession = .shared, retryDelays: [TimeInterval] = [2, 5, 10])
    public func start(_ size: ModelSize)                // resumes from an existing part file
    public func cancel(_ size: ModelSize)               // keeps the part file
    public func phase(of size: ModelSize) -> DownloadPhase
    public var onChange: ((ModelSize, DownloadPhase) -> Void)?   // called on an arbitrary queue
}
```
- [ ] **Step 1: Tests.** Manifest: file names, byte sizes, digests, URL string for medium equals `https://huggingface.co/DamRsn/muscriptor-gguf/resolve/d7045f94e8b19427f4ff9542975035e66596e51c/v1/muscriptor-medium-f16.gguf`, part name `muscriptor-medium-f16.gguf.3850cc9e.part`. Store: a temp dir with a file of the exact size counts as installed, wrong size does not; secondary dir found; resolve order. Downloader (stubbed URLProtocol, tiny 1 KiB "model" specs injected via an `init(specs:)` overload): full 200 download verifies and renames; a 206 with correct `Content-Range` resumes from the part; 416 deletes the part and fails with "The partial download could not be resumed"; corrupted digest → "The download was corrupted. Try again"; over-long body message; cancel keeps the part; 5xx retries with injected zero delays; connect failure → "Could not reach huggingface.co"; HTTP 404 → "huggingface.co answered HTTP 404". Messages per inventory §3.2 verbatim.
- [ ] **Step 2–4:** fail → implement (URLSession data task with delegate streaming to a `FileHandle`, `Range` header, 30 s timeout, `CryptoKit.SHA256` over the part in 1 MiB chunks) → pass.
- [ ] **Step 5: Commit** `core: model manifest, paths, resumable downloader`.

---

### Task 6: MidiFileWriter

**Files:** Create `MidiFileWriter.swift`; test `MidiFileWriterTests.swift`. Depends on Task 3, 4.

**Interfaces (Produces):**
```swift
public enum MidiOverflowMode: Int, Codable, Sendable { case reuseChannels = 0, dropExtraInstruments = 1 }
public struct MidiTrackSpec { public var program: Int; public var name: String; public var channel: Int /* 1-16 */; public var notes: [NoteEvent] }
public enum MidiFileWriter {
    public static let ticksPerQuarterNote = 960
    public static func channelMap(programsAscending: [Int], noteCounts: [Int: Int], mode: MidiOverflowMode) -> [Int: Int]  // program → channel; drums(128) → 10 always
    public static func data(notes: [NoteEvent], bpm: Double, startOffsetSeconds: Double, mode: MidiOverflowMode) -> Data
    public static func exportFileName(sourceFileNameWithoutExtension: String?) -> String   // "<name>_NNTranscription.mid" | "NNTranscription.mid"
}
```
- [ ] **Step 1: Tests.** Channel map: 3 melodic + drums → 1,2,3 + 10; 17 melodic reuse mode → 16th and 17th get channels 11 and 12 (cycle through the last 6 of the melodic list starting at index 9); drop mode keeps the 15 with most notes, ties by lower program. Bytes: for one note (pitch 60, 0.5 s → 1.0 s, program 0, bpm 120) the output starts with `MThd 00000006 0001 0002 03C0`; track 0 contains `FF 51 03 07 A1 20` and `FF 58 04 04 02 18 08`; track 1 contains `FF 03 05 "Piano"`, `C0 00`, note-on `90 3C 64` at delta 960 (VLQ `87 40`), note-off `80 3C 00` (or `90 3C 00` — pick `80` and assert it) at delta 960. Velocity 100 = `Int(round(amplitude * 127))`. `tick = Int(round((t + offset) * bpm / 60 * 960))`. Instrument names from `Instruments.info(forProgram:)`.
- [ ] **Step 2–4:** fail → implement (write helpers `vlq(_:)`, `chunk(_:)`, end-of-track `FF 2F 00`; events per track sorted by tick with note-off before note-on at equal ticks) → pass.
- [ ] **Step 5: Commit** `core: MIDI file writer with channel map and overflow modes`.

---

### Task 7: WaveformPeaks and Resampler

**Files:** Create `WaveformPeaks.swift`, `Resampler.swift`; tests `WaveformPeaksTests.swift`, `ResamplerTests.swift`.

**Interfaces (Produces):**
```swift
public struct PeakPair: Equatable, Sendable { public var min: Float, max: Float }
public final class WaveformPeaks: @unchecked Sendable {   // internally locked
    public static let baseBinSamples = 64, minBinsPerQuery = 16, rawScanMaxSamples = 2048
    public init()
    public func build(from samples: [Float])
    public func append(_ samples: [Float])          // recording path
    public func clear()
    public var sampleCount: Int { get }
    public func peaks(from startSample: Int, to endSample: Int) -> PeakPair   // rules per inventory §2.4
    public func snapshot() -> WaveformPeaksSnapshot  // immutable copy for a paint pass
}
public struct WaveformPeaksSnapshot { public func peaks(from: Int, to: Int) -> PeakPair; public var sampleCount: Int }
public struct Resampler {
    public init(sourceRate: Double, targetRate: Double)   // designs the 4th-order Butterworth at targetRate/2 when downsampling
    public mutating func process(channels: [[Float]]) -> [Float]   // averages channels, filters, Lagrange-interpolates; stateful across calls
    public static func toMono16k(channels: [[Float]], sourceRate: Double) -> [Float]
    public static func resample(channels: [[Float]], from: Double, to: Double) -> [[Float]]   // per-channel, for playback buffers
}
```
- [ ] **Step 1: Tests.** Peaks: 1000 samples of ramp → `peaks(0,64)` equals min/max of the first 64; query across levels equals brute force min/max for random spans (compare against a naive scan on 20 random spans, allowing the coarsening rule: assert the pyramid result *contains* the brute-force range); `append` in chunks of 100 gives the same top-level peak as one `build`. Resampler: 48 kHz 1 kHz sine → 16 kHz output RMS within 10 % of input RMS; 48 kHz 12 kHz sine → output RMS < 5 % of input; output length ≈ n·16000/48000 ± 2; stereo `[L, R]` averages (L = 1, R = −1 → zeros).
- [ ] **Step 2–4:** fail → implement (Butterworth via bilinear transform of the 4 poles → two biquads; Lagrange 4-point interpolation like JUCE's `LagrangeInterpolator`) → pass.
- [ ] **Step 5: Commit** `core: waveform peak pyramid and resampler`.

---

### Task 8: Meters, piano-roll range, zoom math, ruler ticks

**Files:** Create `RmsMeter.swift`, `MeterScale.swift`, `PianoRollRange.swift`, `ZoomMath.swift`, `RulerTicks.swift`; tests for each.

**Interfaces (Produces):**
```swift
public struct RmsMeter {  // fixed ring buffer, allocation-free after init
    public init(sampleRate: Double, windowSeconds: Double = 0.05)
    public mutating func push(_ samples: UnsafeBufferPointer<Float>)   // mono
    public mutating func pushSilence(count: Int)
    public var decibels: Double { get }   // 10*log10(meanSquare), floor -100
}
public enum MeterScale {
    public static let minDb = -36.0, midDb = -12.0, hotDb = -6.0
    public static func litSegments(db: Double, count: Int) -> Int
    public enum Band { case low, mid, hot }
    public static func band(segment: Int, count: Int) -> Band
}
public struct MeterBallistics { public init(); public mutating func advance(input: Double, dt: Double) -> Double }  // instant attack, 24 dB/s release, dt clamped 0.1
public struct PitchRange: Equatable, Sendable { public var low: Int, high: Int /* inclusive MIDI */; public var count: Int; public static let empty = PitchRange(low: 12, high: 83) /* C0..B5 */ }
public enum PianoRollRange {
    public static func displayRange(notes lowest: Int?, highest: Int?, minSemitones: Int) -> PitchRange   // whole octaves, widen above first then alternate, clamp 0..127
    public static func union(_ a: PitchRange, _ b: PitchRange) -> PitchRange
}
public enum ZoomMath {
    public static let basePixelsPerSecond = 100.0, minZoom = 0.1, maxZoom = 5.0
    public static func clampHorizontal(_ z: Double, viewportWidth: Double, duration: Double) -> Double
    public static func contentWidth(zoom: Double, duration: Double, viewportWidth: Double) -> Double
    public static let rowHeightMin = 6.0, rowHeightRange = 37.6
    public static func rowHeight(norm: Double) -> Double
    public static func normForFit(visibleHeight: Double, semitones: Int) -> Double   // inverse, clamped 0...1
}
public enum RulerTicks { public static let divisions: [Double] = [0.1,0.25,0.5,1,2,5,10,15,30,60]; public static let minLabelGap = 56.0; public static func division(pixelsPerSecond: Double) -> Double }
```
- [ ] **Step 1: Tests.** Meter: a 0 dBFS sine gives ≈ −3.0 dB; silence → floor. Scale: `litSegments(0, 26) == 26`, `litSegments(-36, 26) == 0`, `litSegments(-18, 16) == 8`; bands at N=26: 16 low, 17 mid, 21 hot; N=16: 9 low, 10 mid, 13 hot. Ballistics: from 0 dB with input −36 after 1 s → −24. Range: no notes → C0..B5 (12..83); notes 60..67 with min 12 → 60..71 (one octave C4..B4); notes 36..79 → 36..83; widen-above-first when the octave count is below the minimum. Zoom: clamp never below fill-viewport; `rowHeight(0) == 6`, `rowHeight(1) == 43.6`. Ticks: at 100 px/s → 1; at 500 px/s → 0.25; at 20 px/s → 5.
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `core: meters, pitch range, zoom and ruler math`.

---

### Task 9: GlobalSettings, SessionState, VersionCompare

**Files:** Create `GlobalSettings.swift`, `SessionState.swift`, `VersionCompare.swift`; tests for each.

**Interfaces (Produces):**
```swift
public struct GlobalSettings: Codable, Equatable, Sendable {
    public var modelSize: ModelSize = .medium, editorScale: Double = 1.0, tooltipsVisible = true, midiOverflowMode: MidiOverflowMode = .reuseChannels
    public static func load(from url: URL) -> GlobalSettings      // missing/corrupt → defaults
    public func save(to url: URL) throws                          // property list, all keys always written
}
public struct SessionState: Codable, Equatable, Sendable {
    public var exportTempo: Double = 120, midiOverflowMode: MidiOverflowMode = .reuseChannels, sourceAudioPath: String = "",
               playheadSeconds: Double = 0, playheadCentered = true, zoomLevel: Double = 1, verticalZoom: Double = -1,
               selectedGroups: [Int32] = [], mixer: [Int: InstrumentChannelSettings] = [:]
    public static func load(from url: URL) -> SessionState; public func save(to url: URL) throws   // JSON
    public static func parseSelectedGroups(_ csv: String) -> [Int32]   // drops unknown ids, dedups, sorts in enumerator order
}
public enum VersionCompare { public static func isNewer(_ remote: String, than local: String) -> Bool }  // strips v/V, dotted numeric, missing = 0
```
- [ ] **Step 1: Tests.** Settings round-trip; missing file → defaults; a plist missing one key → default for that key. Session round-trip; `parseSelectedGroups("36,0,0,999")` → `[0, 36]`. Version: `isNewer("v2.1", than: "2.0.9")`, `!isNewer("2.0", than: "2.0.0")`, `isNewer("2.0.1", than: "v2")`.
- [ ] **Step 2–4:** fail → implement → pass.
- [ ] **Step 5: Commit** `core: settings, session state and version compare`.

---

### Task 10: PlaybackEngine, SourceAudio, file loading, devices, Ogg decoder

**Files:** Create `Audio/AudioDevices.swift`, `Audio/SourceAudio.swift`, `Audio/AudioFileLoader.swift`, `Audio/PlaybackEngine.swift`, `Decoders/stb_vorbis.c` (copy `/Users/antoni/Projects/NeuralNote/ThirdParty/TinySoundFont/stb_vorbis.c`; add `#define STB_VORBIS_NO_STDIO`-free config so `stb_vorbis_decode_filename` exists), `Decoders/stb_vorbis.h` (a header declaring only `int stb_vorbis_decode_filename(const char*, int* channels, int* sample_rate, short** output)`), add to bridging header. Depends on Tasks 7, 8.

**Interfaces (Produces):**
```swift
struct AudioDevice: Identifiable, Equatable { let id: AudioDeviceID; let name: String }
enum AudioDevices { static func inputs() -> [AudioDevice]; static func outputs() -> [AudioDevice]; static func defaultInput() -> AudioDevice?; static func defaultOutput() -> AudioDevice? }
final class SourceAudio {                       // immutable after load; swapped as a whole
    let deviceRate: Double; let channels: [[Float]] /* at deviceRate */; let mono16k: [Float]
    var duration: Double { Double(mono16k.count) / 16000 }
    let peaks: WaveformPeaks; let droppedFileName: String?; let sourcePath: URL?
}
enum AudioFileLoader {
    static let acceptedExtensions = ["wav", "aiff", "aif", "flac", "ogg", "mp3"]
    static func load(url: URL, deviceRate: Double) throws -> SourceAudio     // AVAudioFile; .ogg via stb_vorbis
    enum LoadError: Error { case unsupportedExtension, decodeFailed }
}
final class PlaybackEngine {
    init()
    var outputDevice: AudioDevice? { get set }; var inputDevice: AudioDevice? { get set }
    var sampleRate: Double { get }
    var inputTap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?   // set by Recorder (Task 11); installed on inputNode bus 0, 1024 frames
    func setSource(_ audio: SourceAudio?)                        // atomically swaps the buffer read by the render block; re-resamples if rate differs
    var isPlaying: Bool { get }; func play(); func pause(); func stop() /* pause + seek 0 */; func seek(seconds: Double)
    var playheadSeconds: Double { get }                          // atomic read
    var mix: Double /* 0…1 */, masterGainDb: Double, muted: Bool   // ramped in the render block
    var masterLevelDb: Double { get }                            // RmsMeter after master gain
    let synthBank: InstrumentSynthBank                           // Task 12; in this task create a stub with the Task 12 interface (init(engine:mixTarget:), schedule(...), allNotesOff(), apply(mixer:), synthGain, levelDb(program:), scheduler, reset()) whose methods are no-ops
    var onPlayheadWrapped: (() -> Void)?                          // called (main queue) when the end is reached: stop + rewind
    func start() throws; func stopEngine()
}
```
- [ ] **Step 1:** Implement `AudioDevices` with CoreAudio `AudioObjectGetPropertyData` (kAudioHardwarePropertyDevices, stream counts to classify input/output, `kAudioObjectPropertyName`). Setting a device on `PlaybackEngine` uses `engine.outputNode.auAudioUnit` / `inputNode.auAudioUnit` `.deviceID` via `kAudioOutputUnitProperty_CurrentDevice` (AudioUnitSetProperty), stopping and restarting the engine.
- [ ] **Step 2:** Implement `AudioFileLoader`: `AVAudioFile(forReading:)`, read all frames into float channels (`processingFormat` float32 non-interleaved), Ogg via `stb_vorbis_decode_filename` (shorts / 32768). Then `SourceAudio` with `channels` = `Resampler.resample(..., to: deviceRate)` and `mono16k = Resampler.toMono16k(...)`, `peaks.build(from: mono16k)`, `droppedFileName = url.deletingPathExtension().lastPathComponent`.
- [ ] **Step 3:** Implement `PlaybackEngine`: `AVAudioEngine`; `AVAudioSourceNode` (stereo float, device rate) whose render block (a) reads the current `SourceAudio` pointer (an `UnsafeMutablePointer<SourceAudio?>`-style atomic box: use a `final class Box` reference swapped via `OSAtomic`-free `withLock`-free pattern — store in an `UnsafeMutablePointer<Unmanaged<SourceAudio>?>` written only from the main thread and read in the block; acceptable because reads are single-word), (b) when playing, copies `frameCount` frames from `playhead − frameCount` (zero before 0) with `sourceGain·masterGain` ramped from the previous block, (c) advances the playhead, (d) calls `synthBank.schedule(from: oldPlayhead, to: newPlayhead, renderTime: timestamp.pointee, frameCount: Int(frameCount), sampleRate: sampleRate)`, (e) wraps to 0 and fires `onPlayheadWrapped` when `playhead ≥ duration`. Mix: `sourceGain = cos(mix·π/2)`, `synthGain = sin(mix·π/2)` (synth gain applied by `InstrumentSynthBank` on the master mixer input of the synth sub-mix). Master gain dB→linear (−36 dB = 0). `muted` → both 0. Master meter: a tap on `mainMixerNode` output feeding `RmsMeter` (mono fold). Request a 128-frame I/O buffer (`kAudioDevicePropertyBufferFrameSize` on the output unit). Play/pause/seek set flags read by the render block; seek also calls `synthBank.allNotesOff()`.
- [ ] **Step 4: Verify.** Build. Add a debug-only code path in `MainView` behind `ProcessInfo.processInfo.environment["NS_AUDIO_SMOKE"]` that loads the env var's file path, plays it for 3 s and prints the playhead every 0.5 s; run the app with the env var pointing at `/System/Library/Sounds/Ping.aiff` and confirm audio and increasing playhead. Remove the debug path before committing.
- [ ] **Step 5: Commit** `audio: playback engine, file loader, devices, ogg decoder`.

---

### Task 11: Recorder

**Files:** Create `Audio/Recorder.swift`. Depends on Task 10.

**Interfaces (Produces):**
```swift
final class Recorder {
    init(engine: PlaybackEngine, paths: AppPaths)
    func start() throws        // creates recorded_audio<YYYY-MM-DD_HH-MM-SS>.wav (native rate, 16-bit, min(channels,2)) and <same>_downsampled.wav (16 kHz mono 16-bit); _1, _2 suffix on collision
    func stop() -> SourceAudio? // flushes, reads both files back, builds SourceAudio (channels from the native file resampled to device rate, mono16k from the downsampled file); nil if zero samples (files deleted)
    var isRecording: Bool { get }
    var durationSeconds: Double { get }   // downsampled samples / 16000, updated per block
    let livePeaks: WaveformPeaks           // appended per block from the downsampled stream
    var nativeFileURL: URL?; var downsampledFileURL: URL?
    enum RecordError: Error { case fileCreation, readBack }
}
```
- [ ] **Step 1:** Implement with `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` (`AVLinearPCMBitDepthKey: 16`), writes from the input tap on a serial `DispatchQueue(label: "NeuralSheet.Recorder")` fed by the tap callback (the tap thread is not the render thread, so a queue is fine). `Resampler` instance kept across blocks. Peaks appended from the downsampled floats.
- [ ] **Step 2: Verify** manually with the same env-var trick (`NS_RECORD_SMOKE=3` records 3 s from the default input, prints both file paths and their frame counts); check with `afinfo` that the files have the right rates/bit depth. Remove the debug path.
- [ ] **Step 3: Commit** `audio: recorder writing native and 16 kHz WAVs`.

---

### Task 12: NoteScheduler and InstrumentSynthBank

**Files:** Create `Audio/NoteScheduler.swift`, `Audio/InstrumentSynthBank.swift` (replace the stub from Task 10). Reference: `/Users/antoni/Projects/NeuralNote/Lib/Player/NoteScheduler.{h,cpp}` and `InstrumentSynth.cpp` (port the scheduler logic faithfully; inventory §5.1–§5.3).

**Interfaces (Produces):**
```swift
struct SynthEvent { var sampleOffset: Int; var program: Int; var pitch: Int; var isOn: Bool }
final class NoteScheduler {   // all methods except swap/seek/allNotesOff are render-thread only
    static let maxActiveNotes = 512, maxLookbackSeconds = 30.0, eventCapacity = 4 * 512
    init()
    func swap(notes: [NoteEvent])                 // main thread: publishes a new immutable sorted array (pointer swap); render re-anchors sounding notes
    func seek(toSeconds: Double)                  // flags: all notes off next block, then re-attack notes covering the playhead within lookback
    func requestAllNotesOff()
    func collect(from t0: Double, to t1: Double, sampleRate: Double, into events: inout [SynthEvent]) // fills pre-reserved array; note-offs before note-ons at equal offsets; every on gets an off
}
final class InstrumentSynthBank {
    init(engine: AVAudioEngine, mixTarget: AVAudioMixerNode)    // creates a synth sub-mixer connected to mixTarget
    func ensureInstrument(program: Int)             // main thread; creates AVAudioUnitMIDISynth + mixer input, sends bank select/program change (melodic: MSB 121, program; drums: MSB 120, program 0 on channel 10)
    func schedule(from t0: Double, to t1: Double, renderTime: AudioTimeStamp, frameCount: Int, sampleRate: Double)  // render thread: collect + AUScheduleMIDIEventBlock one buffer ahead; drum note-offs skipped
    func allNotesOff()                               // CC 123 to every synth (any thread)
    func apply(mixer: InstrumentMixerState)          // main thread: per-input volume (dB→linear, muted/un-soloed → 0), i.e. `isAudible`
    var synthGain: Float { get set }                 // sub-mixer output volume = sin(mix·π/2)
    func levelDb(program: Int) -> Double             // RmsMeter fed by a tap on each synth output (post-fader = multiply by the input gain)
    let scheduler: NoteScheduler
    func reset()                                     // remove all synths
}
```
- [ ] **Step 1:** Port `NoteScheduler` (keep the C++ structure: active-note table with `maxActiveNotes`, oldest stealing, lookback re-anchoring on swap, re-attack after seek/resume, offs expired before and after the onset pass). Pre-reserve `events` with `eventCapacity`.
- [ ] **Step 2:** Implement `InstrumentSynthBank`. `schedule` converts each event to 3-byte MIDI (`0x90|ch`, `0x80|ch`, velocity 100) and calls the synth's `auAudioUnit.scheduleMIDIEventBlock!(AUEventSampleTime(renderTime.mSampleTime) + AUEventSampleTime(frameCount + sampleOffset), 0, 3, bytes)`. Channel 0 for melodic, 9 for drums. Skip drum note-offs. Meter taps: `installTap(onBus: 0, bufferSize: 512, format: nil)` on each synth node feeding its `RmsMeter` scaled by the current input gain.
- [ ] **Step 3: Verify.** Build. Debug path (env `NS_SYNTH_SMOKE=1`): create a scheduler with a C-major scale on program 0 and four drum hits on program 128, play 3 s through the engine, listen. Remove the debug path.
- [ ] **Step 4: Commit** `audio: note scheduler and MIDISynth instrument bank`.

---

### Task 13: Theme, fonts, icons, scale, control primitives

**Files:** Create `UI/Theme.swift`, `UI/Fonts.swift` (extend the Task 1 stub), `UI/Icons.swift`, `UI/Scale.swift`, `UI/Controls/{FlatButton,PillSlider,PopupSurface,TooltipModifier,MenuPanel}.swift`. Reference: `/Users/antoni/Projects/NeuralNote/NeuralNote/Source/UI/{NnLook.h,NnLook.cpp,NnIcons.cpp,NnFonts.cpp,NnFlatButton.cpp}`; inventory §1.8–§1.12.

**Interfaces (Produces):**
```swift
enum Theme { static let bgRoot, bgTopBar, bgSidebar, bgPanel, bgGutter, bgControl, ... : Color  /* every name in inventory §1.8, same names, camelCase */; static let disabledAlpha = 0.38, mutedAlpha = 0.5
             static func surface(idle: Color, on: Color, isOn: Bool, isHovered: Bool, isPressed: Bool, isEnabled: Bool) -> Color   // §1.9
             static func foreground(idle: Color, on: Color, isOn: Bool, isHovered: Bool) -> Color }
extension Color { init(hex: UInt32, alpha: Double = 1); init(_ rgba: RGBA); func darker(_ amount: Double) -> Color; func brighter(_ amount: Double) -> Color }
enum Fonts { static func wordmark(_ s: CGFloat) -> Font; wordmarkVersion, transportTime, transportTotal, filename, instrumentName, buttonLabel, menuItem, menuItemTicked, tempoValue, sectionHeader, pillLabel, statusBar, meta, metaStrong, scaleLabel  /* each takes the ui scale */
             static func tracking(_ em: Double, pointSize: CGFloat, scale: CGFloat) -> CGFloat }   // kerning = em × pointSize × scale
struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }; extension EnvironmentValues { var uiScale: CGFloat }
struct Scaled { let k: CGFloat; func callAsFunction(_ v: CGFloat) -> CGFloat { v * k } }   // views do `@Environment(\.uiScale) var k` then `let s = Scaled(k: k)` and write `s(54)`
enum Icons { struct SkipToStart: Shape; Play; Pause; Record; LoopStroked; LoopHead; FollowPlayheadStroked; FollowPlayheadFlag; Speaker; SpeakerMuted; SettingsStroked; FolderStroked; DownloadStroked; TrashStroked; TriangleUp; TriangleDown; PlusStroked; CrossStroked; CheckStroked; TranscribeStroked; VerticalZoomStroked
             static let strokeWidth: CGFloat = 1.3 }
struct FlatButton<Label: View>: View  // init(isOn: Bool = false, isEnabled: Bool = true, idle: Color, on: Color, corner: CGFloat, action: () -> Void, @ViewBuilder label: (ButtonVisualState) -> Label); tracks hover/press; applies Theme.surface/foreground and disabledAlpha
struct ButtonVisualState { var isHovered, isPressed, isOn, isEnabled: Bool }
struct PillSlider: View   // init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, width: CGFloat, fill: Color, track: Color, thumb: Color?, onDoubleClick: (() -> Void)?)
struct PopupSurface: ViewModifier   // popupBg fill, 1 px popupBorder, corner radius param, shadow black@55 % radius 34 offset (0,14) optional
struct TooltipModifier: ViewModifier  // .tooltip("text") — 800 ms delay, 260 max width, PopupSurface, positioned away from the nearest screen edge; global enable flag `Tooltips.enabled`
struct MenuPanel<Content: View>: View // width 244, corner 8, header 28 / footer 29 / rows 30, list max height 274 scrolling, per §1.12
```
- [ ] **Step 1:** Implement `Theme` with every colour from §1.8 (names identical, e.g. `Theme.accentFillActive = Theme.accent.opacity(0.14)`).
- [ ] **Step 2:** Implement `Fonts` (font names: "Inter", "Inter Medium", "Inter SemiBold", "Inter Bold", "JetBrainsMonoNL-Regular", "JetBrainsMonoNL-Medium", "JetBrainsMonoNL-SemiBold" — verify the PostScript names with `fc-scan` or `CTFontManager` after registration and use those) and tracking helper.
- [ ] **Step 3:** Port every icon path from `NnIcons.cpp` into `Shape`s in a unit square scaled to `rect`.
- [ ] **Step 4:** Implement the control primitives. `TooltipModifier` uses an `NSWindow` child panel (`NSPanel`, non-activating) or a SwiftUI overlay in the window's root `ZStack` via a `TooltipHost` preference — pick the panel approach so tooltips escape clipping.
- [ ] **Step 5: Verify:** a temporary `#Preview` gallery in `UI/Controls/Gallery.swift` (keep it; previews cost nothing) showing all icons, a FlatButton in each state, a PillSlider, and a MenuPanel. Build.
- [ ] **Step 6: Commit** `ui: theme, fonts, icons, scale and control primitives`.

---

### Task 14: AppModel

**Files:** Create `App/AppModel.swift`, `App/AppModel+Transcription.swift`. Depends on Tasks 2–12. Reference: inventory §3.4, §11.1, §11.5; C++ `TranscriptionManager.cpp`, `NeuralNoteMainView.cpp`, `PluginProcessor.cpp`.

**Interfaces (Produces — the contract every view task relies on; add members freely but do not rename these):**
```swift
@MainActor @Observable final class AppModel {
    // dependencies
    let paths: AppPaths; let engine: PlaybackEngine; let recorder: Recorder; let transcriber: TranscriptionEngine
    let modelStore: ModelStore; let downloader: ModelDownloader
    // state
    private(set) var state: AppState
    private(set) var source: SourceAudio?            // nil when empty/recording
    var duration: Double                             // 0 when none; live while recording
    var droppedFileName: String?                     // toolbar title; nil for recordings
    var peaks: WaveformPeaks                         // live during recording, source.peaks otherwise
    private(set) var notes: [NoteEvent]              // post-processed
    private(set) var finalizedThrough: Double
    private(set) var transcriptionProgress: Float
    private(set) var cancelLatched: Bool
    var selectedGroups: [InstrumentGroup]            // sorted enumerator order; empty = Automatic
    var selectedPrograms: [Int]
    private(set) var mixer: InstrumentMixerState
    var isPlaying: Bool; var playheadSeconds: Double  // playhead refreshed by the display link tick
    var followPlayhead: Bool; var inputMuted: Bool /* the MUTE button */; var mix: Double; var masterGainDb: Double
    var zoomLevel: Double; var verticalZoom: Double /* -1 = auto */
    var exportTempo: Double; var settings: GlobalSettings
    var modelSize: ModelSize?; var installedModels: Set<ModelSize>; var downloadPhases: [ModelSize: DownloadPhase]
    var isModelPanelOpen: Bool; var isModelPanelMandatory: Bool
    var isInstrumentMenuOpen: Bool
    var updateNotice: UpdateNotice?                  // struct { text: String; showsSeeUpdate: Bool; expiresAt: Date }
    var masterLevelDb: Double; func instrumentLevelDb(program: Int) -> Double   // meter inputs, staleness rule applied
    var statusLine: (instruments: Int, notes: Int, lowest: Int?, highest: Int?)
    // commands
    func toggleRecord(); func loadAudio(url: URL); func clear(); func clearTranscription()
    func launchTranscription(); func cancelTranscription()
    func togglePlay(); func goToStart(); func seek(toSeconds: Double)
    func setSelected(_ g: InstrumentGroup, _ on: Bool); func clearSelection()
    func setGain(program: Int, db: Double); func setMuted(program: Int, _ m: Bool); func setSoloed(program: Int, _ s: Bool)
    func setModelSize(_ s: ModelSize); func startDownload(_ s: ModelSize); func cancelDownload(_ s: ModelSize); func openModelsFolder()
    func midiData() -> Data?; func midiExportFileName() -> String; func writeMidiForDrag() -> URL?; func exportMidi()   // exportMidi presents the NSSavePanel
    func checkForUpdates(explicit: Bool); func dismissUpdateNotice()
    func resetZoom(); func setEditorScale(_: Double)
    func displayLinkTick(dt: Double)                 // called by MainWindow's display link: playhead, meters, notice timers
    var canRecord: Bool; var canTranscribe: Bool; var canExport: Bool; var transcribeLabel: String  // "Transcribe" / "Transcribe 1 instrument" / "Transcribe N instruments"
    var timeReadout: (position: String, total: String)
}
```
- [ ] **Step 1:** Implement state transitions exactly per inventory §11.1 / §3.4 (steps 1–9, incl. ≥ 1 s rule, `mixer.resetStoredSettings()`, `cancelLatched`), the 30 Hz drain timer while processing (merge staged notes, `mergeOverlappingNotesWithSamePitch`, `mixer.update(notes:selectedPrograms:)`, `engine.synthBank.scheduler.swap(notes:)`, `ensureInstrument` for new programs, `apply(mixer:)`), the completion path (replace notes with the authoritative result, `finalizedThrough = duration`, state populated) and the failure dialog strings (§3.4, incl. the unsupported-version text). Model panel mandatory rule (§3.2): no installed model and state ∈ {empty, audioLoaded}. Download phase updates via `downloader.onChange` hopped to the main actor; 10 Hz re-scan of installed models while the panel is open.
- [ ] **Step 2:** Recording: `toggleRecord` allowed in empty/recording only; while recording, `duration` and `peaks` come from the recorder; stop → `source = recorder.stop()`, state audioLoaded, or clear on nil. Clear deletes only files under `paths.recordings` with prefix `recorded_audio`.
- [ ] **Step 3:** MIDI: `midiData()` uses `MidiFileWriter.data(notes:bpm: exportTempo, startOffsetSeconds: 0, mode: settings.midiOverflowMode)`; only when state == populated.
- [ ] **Step 4: Verify:** build; a throwaway `#Preview` is not useful here — instead add `AppModelSmokeTests`? The app target has no test bundle; verify by wiring a minimal `MainView` with a Load button, a Transcribe button, a Play button and a `Text` of `notes.count` and running end-to-end on a short audio file with the installed model. Keep this minimal MainView; Task 20 replaces it.
- [ ] **Step 5: Commit** `app: AppModel state machine and transcription pipeline`.

---

### Task 15: TopBar and TimeDisplay

**Files:** Create `UI/TopBar/TopBar.swift`, `UI/TopBar/TimeDisplay.swift`. Inventory §1.3, tooltips §11.4. Consumes `AppModel`, Task 13 primitives.

- [ ] **Step 1:** Build `TopBar(model:)` at height `s(54)`: wordmark ("NEURALSHEET" + "v1"), 5 transport buttons 34×30 (loop disabled with tooltip "Loop (not implemented yet)"), `TimeDisplay`, Model button (`MODEL: SMALL|…|NONE`, lit while the panel is open), spacer, mix pill (ORIG … MIDI, 86 px slider, dimmed 0.38 when `notes.isEmpty`), volume pill (speaker, 74 px slider, 30 px dB readout, dimmed unless `canPlay`), MUTE button, settings button (32 px; opens `SettingsMenu` from Task 20 via a closure `onSettings`). Colours/fonts/paddings verbatim.
- [ ] **Step 2:** `TimeDisplay` repaints only when the string changes (compare in `onChange`).
- [ ] **Step 3: Verify:** `#Preview` with a stub `AppModel` in each state; build; run the app and compare against the C++ app side by side (`open /Users/antoni/Projects/NeuralNote/build/NeuralNote_artefacts/Release/Standalone/NeuralNote.app`).
- [ ] **Step 4: Commit** `ui: top bar and time display`.

---

### Task 16: Sidebar, InstrumentStrip, MasterPanel, LevelMeter, InstrumentMenu

**Files:** Create the five files under `UI/Sidebar/`. Inventory §1.4, §1.5, §2.5 (meters), §3.3 (menu), §11.4.

- [ ] **Step 1:** `LevelMeter(db: Double, segments: Int, gap: CGFloat, height: CGFloat)` — uses `MeterScale`; repaints only when the lit count changes; ballistics applied by the caller (`AppModel.instrumentLevelDb` already ballistic).
- [ ] **Step 2:** `InstrumentStrip(entry:settings:level:)` 262×76 with chip, name (strike-through when muted), meta line variants, M/S toggles, fader (−36…+6, step 0.1, double-click resets), dB readout, 16-segment meter; disabled when placeholder; muted alpha 0.5; solo row tint.
- [ ] **Step 3:** `Sidebar` header (INSTRUMENTS, count, "+" hidden when `hasTranscription`), scrolling strip list, `MasterPanel` (63 px, 26-segment meter).
- [ ] **Step 4:** `InstrumentMenu` — a `MenuPanel` overlay covering the main view with a scrim (click or Esc closes), anchored at sidebar `(262−10, 33)`, row 0 "Automatic (any instrument)", then 35 rows toggling `model.setSelected`, header "ADD INSTRUMENT", footer "TICK TO INCLUDE IN TRANSCRIPTION", shadow 34/(0,14). Exposed as `InstrumentMenuOverlay(model:)` for Task 20 to place in the root ZStack.
- [ ] **Step 5: Verify** with previews and the running app; **Commit** `ui: sidebar, instrument strips, meters and instrument picker`.

---

### Task 17: Toolbar, TempoField, StatusBar, TranscriptionProgress

**Files:** Create `UI/Toolbar/Toolbar.swift`, `UI/Toolbar/TempoField.swift`, `UI/StatusBar/StatusBar.swift`, `UI/StatusBar/TranscriptionProgress.swift`. Inventory §1.6, §1.7, §3.5, §6.1.

- [ ] **Step 1:** `Toolbar`: file name (only when `droppedFileName != nil`), Clear button (right-click context menu "Clear audio and transcription" / "Clear transcription only"), Drag-MIDI button (`.onDrag { NSItemProvider(contentsOf: model.writeMidiForDrag()) }`, hand cursor on hover, enabled only in populated), Export button (`model.exportMidi()`), EXPORT TEMPO pill with `TempoField` (40 px, digits and "." only, max 6 chars, commit validates 20…999, empty → 120) and the two decorative triangles.
- [ ] **Step 2:** `StatusBar`: segments joined by ` · ` per §1.7, `TranscriptionProgress` (pulsing caption 1600 ms raised cosine 0.55…1.0, 150×3 bar, %, cancel cross, latched dimming) 24 px left of the vertical-zoom control (icon + 74 px slider bound to `verticalZoom` where slider 0…1 maps to the norm and −1 shows the fit value).
- [ ] **Step 3: Verify** previews + app; **Commit** `ui: toolbar, tempo field, status bar and progress`.

---

### Task 18: ModelPanel

**Files:** Create `UI/ModelPanel/ModelPanel.swift`. Inventory §3.2 (panel UI), §11.4.

- [ ] **Step 1:** 440-wide popup surface with the title/subtitle variants, three 46 px rows (checkbox dimmed when not installed, name, meta line: size + hint / "120 MB of 618 MB" / error in `warn`), right column 172 px (Download/Resume/Retry button, or progress bar 3 px + "%" + cancel cross, or "VERIFYING"), footer "Open models folder", close cross only when not mandatory. Clicking an installed row → `model.setModelSize`. Exposed as `ModelPanelOverlay(model:)` anchored below the Model button (Task 20 places it).
- [ ] **Step 2: Verify** preview + app (download the small model for real: ≈ 209 MB); **Commit** `ui: model panel`.

---

### Task 19: Timeline (AppKit): waveform, ruler, piano roll, keyboard, gutter, playhead, overlays

**Files:** Create everything under `UI/Timeline/`. Inventory §1.2 (gutter/keyboard column), §7 entirely, §5.1 (click-to-seek), §2.2 (drop target). Reference C++: `Components/{AudioRegion,PianoRoll,CombinedAudioMidiRegion,Views/VisualizationPanel,TimeRuler,TimelineGutter,Playhead,WaveformBars}.{h,cpp}`, `UI/Keyboard.cpp`.

**Interfaces (Produces):**
```swift
final class TimelineGeometry {   // shared by all timeline views; main-thread
    var scale: CGFloat; var zoom: Double; var duration: Double; var viewportWidth: CGFloat
    var pixelsPerSecond: CGFloat { 100 * zoom * scale }; var contentWidth: CGFloat
    var pitchRange: PitchRange; var rowHeight: CGFloat
    func x(forSeconds: Double) -> CGFloat; func seconds(forX: CGFloat) -> Double
    func y(forPitch: Int) -> CGFloat   // top of the lane
}
struct TimelineView: NSViewRepresentable { init(model: AppModel) }   // the whole gutter+keyboard+scrollview block; sizes itself to the given frame
```
- [ ] **Step 1:** `TimelineContainerView` (NSView): left column 46 px (`GutterView` for waveform+ruler rows, `KeyboardView` below), right an `NSScrollView` (horizontal scroller only, thin, thumb `faderTrack`, transparent track) with a document `NSView` stacking `WaveformView` (126), `RulerView` (22), `PianoRollView` (rest). All three draw only `dirtyRect` via CoreGraphics.
- [ ] **Step 2:** `WaveformView`: bars 3 px wide, 4 px pitch, symmetric, absolute-pixel anchored, min height 1, centre line white@5 %, played wash + edge, "MIX WAVEFORM" label; empty-state overlay (`EmptyWaveformOverlay`: dashed panel, "Load audio file" button opening an `NSOpenPanel` filtered to `AudioFileLoader.acceptedExtensions`, hint text, drag-over highlight) shown when `state == .empty`; registers for file drops (`registerForDraggedTypes([.fileURL])`) accepted in empty/audioLoaded/populated, calling `model.loadAudio`, with the "Could not load the file." alert for bad extensions.
- [ ] **Step 3:** `RulerView` per §7.4; `PianoRollView` per §7.5 (lanes, octave separators, notes with onset edge, muted alpha 0.16, drum min 0.1 s, frontier shading, wash left of playhead, `TranscribeCTA` centred overlay when idle roll + model installed (label from `model.transcribeLabel`, enabled in audioLoaded)). `KeyboardView` per §7.2 (vertical, white keys `rowHeight×12/7`, black 0.58/0.65, "C<n>" labels, dimmed 40 % when no notes, wheel scrolls pitch). `GutterView` per §7.2 (amplitude labels at exact y).
- [ ] **Step 4:** `PlayheadLayer` (CALayer, 1 px `textBright`, plus the 9 px triangle on the waveform copy) positioned from `model.playheadSeconds` on each display-link tick; hidden in empty/audioLoaded. Click-to-seek on waveform and roll (`0 <= t < duration`).
- [ ] **Step 5:** Interactions: ⌘-wheel and magnify zoom anchored at the left edge; plain wheel: vertical over the roll → pitch scroll, horizontal → time; follow-playhead centring per tick while playing; auto-scroll right while recording; `goToStart` scrolls to the left edge; vertical zoom from `model.verticalZoom` (auto = `ZoomMath.normForFit`), range widening only during processing and re-settling on state change.
- [ ] **Step 6: Verify:** run with a real transcription; scroll, zoom, seek; compare with the C++ app. **Commit** `ui: AppKit timeline with waveform, ruler, piano roll and keyboard`.

---

### Task 20: Window, MainView composition, settings menu, update notice, shortcuts, dialogs, session, audio device menu

**Files:** Create `App/MainWindow.swift`, `App/KeyboardShortcuts.swift`, `App/Dialogs.swift`, `App/UpdateCheck.swift`, `App/AppModel+Session.swift`, `UI/SettingsMenu.swift`, `UI/UpdateNotice.swift`; rewrite `UI/MainView.swift`; extend `App/NeuralSheetApp.swift` (menu bar: an "Audio" menu with Input/Output device submenus bound to `engine.inputDevice/outputDevice`). Inventory §1.1, §1.2, §8, §9, §11.2, §11.3, §11.7.

- [ ] **Step 1:** `MainView`: the 1280×800 composition (top bar 54; sidebar 262 | toolbar 44 + timeline; status bar 26) with `.environment(\.uiScale, scale)` and the overlays (instrument menu, model panel, update notice at `(right−460, bottom−26−10−30, 449, 30)`, tooltips host).
- [ ] **Step 2:** `MainWindow`: on appear, grab the `NSWindow` (via an `NSViewRepresentable` hook), set `contentAspectRatio = NSSize(width: 1280, height: 800)`, `contentMinSize = 640×400`, `contentMaxSize` from the display rule (§1.1), restore `settings.editorScale`, write the scale back on close (skip if |Δ| < 0.0005). Run a `CVDisplayLink`/`NSView.displayLink` calling `model.displayLinkTick(dt:)`.
- [ ] **Step 3:** `SettingsMenu` (SwiftUI `Menu`-free: a `MenuPanel` popover from the gear) with the six §11.3 items; window-size presets set the window frame.
- [ ] **Step 4:** `UpdateCheck` (URLSession GET `https://api.github.com/repos/antoni/neural-sheet/releases/latest`, `tag_name`, `VersionCompare`), `UpdateNotice` view (texts with "NeuralSheet", "See update" button opening `https://github.com/antoni/neural-sheet/releases/latest`, 10 s auto-dismiss extended to now+3 s while hovered, 5 Hz tick).
- [ ] **Step 5:** `KeyboardShortcuts`: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` mapping Space, Shift+Space, Shift+Backspace, r, m, c, Esc per §11.2 (ignore when a text field is first responder).
- [ ] **Step 6:** `Dialogs`: `NSAlert` helpers with every §11.7 string; wire them from `AppModel` via a `presentError: (title, body) -> Void` closure set by `MainView`.
- [ ] **Step 7:** Session: save `SessionState` on `NSApplication.willTerminateNotification` and after each change of its fields (debounced 500 ms); restore on launch (load audio from `sourceAudioPath` if it exists, restore playhead/zoom/selection/mixer/tempo). Delete `paths.midiScratch` on terminate.
- [ ] **Step 8: Verify** the full flow in the app: record 5 s, transcribe, play, mix, mute/solo, drag MIDI into Finder, export, quit, relaunch and see the session restored. **Commit** `app: window, composition, settings, update check, shortcuts, dialogs, session`.

---

### Task 21: Parity pass

- [ ] **Step 1:** An Opus agent reads the inventory top to bottom and, for each non-[PLUGIN] bullet, finds the Swift code implementing it or records a gap in `docs/superpowers/plans/2026-09-17-parity-gaps.md` (section, bullet, missing/wrong, file to fix).
- [ ] **Step 2:** Run the app next to the C++ app with the same audio file and the same model; screenshot both (`screencapture -l <windowid>`), compare layout region by region; add visual gaps to the same file.
- [ ] **Step 3:** Fix every gap (one commit per group of related gaps), re-run the package tests and the build.
- [ ] **Step 4:** Commit the gap file with all items ticked: `docs: parity pass against the NeuralNote inventory`.
