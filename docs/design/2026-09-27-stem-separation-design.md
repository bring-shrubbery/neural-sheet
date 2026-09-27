# Stem separation — Design

The model transcribes a mix as one signal, and a full band is where it does worst: the bass
bleeds into the piano, the vocal line comes out as a synth, the drums smear the onsets. Moises,
Logic and every recent transcription service separate the mix into stems first and transcribe
each on its own. This adds **Stems**: with the toggle on, Transcribe separates the take into
drums, bass, vocals and everything else with the Hybrid Transformer Demucs model, transcribes
each stem with the instruments that belong to it, and lands the four results as one
transcription.

It builds on the transcription pipeline (`docs/design/2026-09-17-neuralsheet-design.md` §3.4 of
the inventory) and the model download flow (§3.1, §3.2). Everything it does not mention is
unchanged.

## 1. Goals and non-goals

Goals

- One toggle on the Transcribe toolbar; the rest of the flow is unchanged: the same Transcribe
  button, the same progress group, the same cancel, the same result in the roll.
- The separation runs on device, in the same static-library shape as the transcription engine:
  a C++ library built by the engine build script, a C bridge, a Swift wrapper on its own thread.
- The weights are one more downloadable model in Settings › Model, fetched, resumed and
  verified by the existing downloader.
- Each stem is transcribed with the instruments it can hold: the drums as Drums, the bass as the
  two basses, the vocals as Voice, and the rest with the user's selection less those three, or
  every other instrument when the selection is Automatic.

Non-goals

- Playing or exporting the stems. They are an intermediate; the result is notes.
- Cancelling the separation mid-way. The library's callback reports and cannot stop; a cancel
  abandons the result and the thread finishes on its own. The transcription runs after it
  cancel as they always did.
- The 6-stem or fine-tuned Demucs variants. The 4-stem model is 84 MB; the fine-tuned set is four
  of them.
- Third-party notices. `THIRD_PARTY_NOTICES.md` is a maintainer's file (AGENTS.md); this design
  adds demucs.cpp (MIT), Eigen (MPL 2.0) and the HTDemucs weights (MIT) and says so, and the
  maintainer adds the entries before the release that ships this.

## 2. Decisions

| Question | Decision |
|---|---|
| Library | `sevagh/demucs.cpp`, a C++17 port of Demucs v4 with Eigen as its only dependency, as a git submodule at `app/ThirdParty/demucs.cpp` (its own `vendor/eigen` submodule with it). Built into `libdemucs.a` by `Scripts/build-engine.sh` through `Scripts/stems/CMakeLists.txt`, with Eigen over Accelerate's BLAS and no OpenMP. |
| Weights | `ggml-model-htdemucs-4s-f16.bin` from the `Retrobear/demucs.cpp` dataset on Hugging Face, pinned to a commit, 83 994 361 bytes, SHA-256 `72b17c42…`. |
| Where the weights live in the manifest | `ModelSize.stems`, beside the three transcription sizes, so the store, the downloader, the part files and the Settings rows all work as they are. `ModelSize.transcription` lists the three the transcriber chooses from; every place that meant "a transcription model" reads that. |
| Threads | The take is cut into four stretches with 0.75 s of overlap, one thread each, and the results crossfaded back together, as the library's own multi-threaded driver does. Four rather than every core: each thread holds its own segment buffers. |
| Rates | Demucs is 44.1 kHz stereo; the take is resampled there from its device rate, and each stem back to the model's 16 kHz mono. |
| Instruments per stem | Drums → Drums. Bass → Acoustic Bass, Electric Bass. Vocals → Voice. Other → the selection less those three, or every named group but those three. |
| Progress | The separation is the first half of the bar, the four runs the second, a quarter each. The caption reads SEPARATING while the separator runs. |
| Cancel | The status bar's cross: during the separation the result is abandoned; during a stem's run the engine is cancelled. Either way the take stays loaded, as a cancelled run leaves it. |
| Failure | The transcription's failure dialog, with the separation's own message: `"The stems could not be separated: <reason>."` |
| The toggle | `Stems` on the Transcribe toolbar, a `FlatButton` lit on the accent while on; dimmed with the tooltip `"Download the Stems model in Settings › Model"` when the weights are not installed. Remembered in the global settings (`separateStems`). |
| Settings › Model | A second section, "Stem separation", with the Stems row: installed, or download with progress and cancel; its footer names the weights' licence and links the dataset. |
| The roll while separating | Nothing: the roll is empty until the first stem's notes stream in, as the whole run's used to be for its first chunk. |

## 3. Engine (`Engine/nsheet_stems.h`, `Engine/nsheet_stems.cpp`, `Engine/StemSeparator.swift`)

```c
typedef struct nsheet_separator nsheet_separator;
typedef void (*nsheet_stems_progress_fn)(float progress, void* ctx);
nsheet_separator* nsheet_stems_load(const char* model_path);            // null on failure
int nsheet_stems_separate(const nsheet_separator*, const float* left, const float* right,
                          size_t frames, int threads, nsheet_stems_progress_fn cb, void* ctx,
                          float** out_stems);   // 4 × 2 × frames planar, malloc'd; NSHEET_STEMS_OK
void nsheet_stems_free_audio(float* stems);
void nsheet_stems_free(nsheet_separator*);
```

The bridge includes the library's headers under diagnostic pragmas, as `stb_vorbis.c` is; the
library itself is built by CMake with its own flags. The threaded split is the library's driver
in C form: `threads` stretches of the take with 0.75 s either side, each through
`demucs_inference` on a `std::thread`, the outputs summed under a triangular weight and
normalised. Progress is the mean of the threads' own.

`StemSeparator` is `nonisolated`, `@unchecked Sendable` with a lock, one run at a time:
`run(modelPath:source:onProgress:completion:)` starts a thread that resamples the take to
44.1 kHz stereo (a mono take feeds both channels), calls the bridge, resamples each stem to
16 kHz mono and completes with `Stems { drums, bass, other, vocals: [Float] }` or an error
message. `cancel()` marks the run abandoned: the completion is not delivered.

## 4. Core

- `ModelSize.stems` (display name "Stems", hint "Separates drums, bass and vocals first");
  `ModelSize.transcription: [ModelSize]`; `ModelStore.installed()` still answers for every size,
  `resolve(preferred:)` only among `transcription`.
- `ModelManifest.spec(for: .stems)` with the dataset URL and digest above.
- `GlobalSettings.separateStems: Bool`, default false.
- `TranscriptionState.stemsPhase` is not needed: the job lives on `AppModel` as
  `StemsJob`.

Tests: the manifest covers four sizes and the stems spec's file name, size, digest and URL; the
store's `resolve` never answers `.stems`; the settings round-trip `separateStems` and default it
to false for an older file.

## 5. App (`App/AppModel+Stems.swift`)

```swift
struct StemsJob {
    let id = UUID()
    var phase: Phase                 // .separating, .transcribing(stem: Int)
    var stems: StemSeparator.Stems?
    var notes: [NoteEvent] = []     // the finished stems' results
    var modelPath: URL              // the transcription checkpoint
}
```

- `launchTranscriptionNow` step 9 becomes: with `settings.separateStems` and the stems model
  installed, `launchStemsRun(modelPath:)` instead of the single run. The state, the staging and
  the drain are set up as before; `transcription.jobActive` stays true for the whole job.
- The separator's progress maps to `0 … 0.5`; its completion starts stem 0's run. Each stem's
  run streams into the same staging (the drain draws notes as they come, whatever stem they are
  from), its progress maps to `0.5 + (stem + p) / 8`, and its final notes are appended to the
  job; stem 3's completion installs the document from the four results and goes to
  `.populated`.
- `cancelTranscription` latches and cancels whichever is running; the separator's abandoned
  completion never arrives, the engine's cancel lands as before. `handleFinished`'s cancel and
  failure paths are shared.
- `hasTranscriptionModel`, `hasStemsModel` on the model; `needsModelNotice` and the CTA read the
  first.

## 6. UI

- `Toolbar`: the `Stems` toggle between the file name and Re-transcribe.
- `ModelSettingsView`: the "Stem separation" section.
- `TranscriptionProgress`: caption `SEPARATING` while `stemsJob?.phase == .separating`.

## 7. Departures from the inventory

- §3.4: a run may be four runs over separated stems. NeuralNote transcribed the mix.
- §3.1: a fourth downloadable model that is not a transcription checkpoint.

## 8. Tests and verification

- Core tests as in §4; build warning-free; `swift test` green; the engine build script builds
  `libdemucs.a` from a clean `build/`.
- By hand: download Stems in Settings; toggle Stems; Transcribe a song; the drums land as
  Drums, the bass as a bass, the vocal as Voice; cancel during SEPARATING leaves the take
  loaded.

## 9. Order of work

1. **chore**: the submodule.
2. **engine**: the CMake project and the build script, the link settings, the bridge, the wrapper.
3. **core**: the manifest, the store, the setting, tests.
4. **app**: the stems job and the pipeline.
5. **ui**: the toggle, the settings section, the caption.
6. **docs**: AGENTS.md departures, the changelog, the notices reminder.
