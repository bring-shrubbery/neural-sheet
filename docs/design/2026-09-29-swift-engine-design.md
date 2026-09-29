# The transcription engine in Swift — Design

NeuralSheet transcribes with [muscriptor.cpp](https://github.com/DamRsn/muscriptor.cpp), a C++23
port of MuScriptor over ggml, built by CMake as a static library and driven through a C bridge
(`Engine/nsheet_engine.h`). That works on the Mac and nowhere else the app wants to go: an iOS or
iPadOS build would have to cross-compile ggml, its Metal shaders and pffft, keep a C++ toolchain in
the loop, and ship a bridging header. This design replaces the engine with a **Swift package,
`NeuralSheetEngine`**, that reads the same GGUF checkpoints, runs the same model on Accelerate or
Metal, and returns the same notes, on macOS and iOS alike, with no C or C++ in the path.

It builds on the transcription pipeline of `2026-09-17-neuralsheet-design.md` (§3.4 of the
inventory) and the model download flow (§3.1, §3.2). Everything it does not mention is unchanged:
the app downloads the same files from the same repository, the Settings window shows the same
sizes, the piano roll fills in the same way, the notes come out in the same order.

## 1. Goals and non-goals

Goals

- A pure-Swift engine: the GGUF loader, the STFT and mel front-end, the transformer, greedy
  decoding, the MT3 decode state machine, prelude forcing, instrument selection and note assembly,
  every piece of it Swift over Apple frameworks (Foundation, Accelerate, Metal). It builds for
  macOS, iOS and the iOS simulator from one `Package.swift`.
- The same output. On the engine's own audio fixture the Swift port reproduces muscriptor.cpp's
  token streams chunk for chunk and its note lists variant for variant, on the CPU and on Metal,
  for the `small` and `medium` checkpoints. The C++ library is the oracle: its outputs are dumped
  once, committed as test fixtures, and the Swift tests are a ladder against them, stage by stage,
  the way muscriptor.cpp's own tests are a ladder against PyTorch.
- Two compute backends behind one protocol: **CPU** on Accelerate (the correctness reference and
  the fallback) and **Metal** (what the app runs). Metal within about twice the speed of ggml's
  Metal backend on the same machine; the CPU backend no slower than ggml's CPU backend.
- The app unchanged from the user's seat. `TranscriptionEngine` keeps its shape (`run`, `cancel`,
  `isRunning`, the update and completion callbacks on the engine's thread) and `AppModel` keeps
  its contract; the C bridge, the ggml archives, the CMake step for the engine and the
  `muscriptor.cpp` submodule go.
- Every rule under `swift test`. Tests that need a checkpoint skip when none is installed; the
  pure tests (vocabulary, tracker, assembly, tables, GGUF parsing, STFT, positions) run anywhere.

Non-goals

- Porting `demucs.cpp`. Stem separation is a separate, optional library (stem separation design),
  eight thousand lines of Eigen code with no reference dump to check a port against. It stays a
  static library on the Mac; its Swift port is a follow-up with its own design. The app still
  links it, so the app target itself is not yet iOS-clean; the engine package is.
- Quantised checkpoints. The published files are F16 (F32 for the conditioning path); those are
  the two dtypes the loader reads.
- Intel Macs. The app is arm64 only already; the package uses `Float16`, which Swift does not
  offer on x86_64 macOS.
- Vulkan, Windows, Linux: not the app's platforms.
- Faster than ggml. Parity first; the kernels are written to be correct and simple, and a
  benchmark target keeps the numbers visible for later work.
- A Core ML or MLX path. Core ML would be a conversion, not a port, and would need its own model
  files hosted somewhere; MLX Swift is a C++ library under a Swift API, which is what this design
  removes.

## 2. Decisions

| Question | Decision |
|---|---|
| Shape | A local Swift package, `app/Packages/NeuralSheetEngine`, beside `NeuralSheetCore`, `platforms: [.macOS(.v26), .iOS(.v26)]`, Swift 5 language mode like the core package, no dependencies. The app links it as it links the core. |
| Public surface | `Transcriber` (`load(path:options:)`, `transcribe(samples:options:onUpdate:)`, `backendName`), `TranscribeOptions` (`instruments`, `preludeForcing`), `TranscriptionUpdate`, `Note`, `InstrumentGroup`, `TranscriberError`. The same seam as the C++: 16 kHz mono float32 in, notes out; decoding, resampling, MIDI and threading are the caller's. |
| Weights in memory | The GGUF is memory-mapped. The CPU backend reads F16 weights straight out of the map. The Metal backend copies the tensor data region into one `MTLBuffer` (shared storage on Apple silicon) and addresses tensors by offset. |
| Precision | Weights F16 as stored, converted to F32 inside the kernels; activations, the KV cache, the conditioning path and the position table F32. This is at least as close to the fp32 reference as ggml is: ggml's CPU rounds activations to F16 before an F16 matmul, ggml's Metal rounds F32 matmul inputs to half. The tests allow for that gap the way muscriptor.cpp's do (§6). |
| CPU kernels | Accelerate: vDSP for the FFT, the mel and the elementwise work; `cblas_sgemm` for prefill matmuls after a vImage half-to-float conversion of the weight; a hand-written `Float16` SIMD GEMV for single-token decode, rows split across `DispatchQueue.concurrentPerform`. GELU in its exact erf form. |
| Metal kernels | Metal Shading Language in a Swift string, compiled once per process with `makeLibrary(source:)`. Kernels: F16 matvec and matmul with F32 accumulation, layer norm, GELU (erf), masked softmax, attention scores and weighted sum over the cache, embedding add, residual add. One command buffer per forward pass. No `.metal` files, no metallib in a bundle: the same code path under `swift test`, in Xcode and on iOS. |
| Backend protocol | `TransformerBackend`: `reset()`, `forward(input: [Float], nNew: Int, nPast: Int) throws -> [Float]`. It owns the layer weights and the KV cache, takes the layer-0 input (embeddings plus positions, already assembled on the CPU) and returns the raw logits of the last position. Everything above it (prefix assembly, positions, logit masking, greedy decoding) is one Swift `Model` shared by both backends. |
| KV cache | Per layer, K and V each `[nCtx][dim]` F32, row per position. The transposed V of the C++ was for ggml's matmul; with our own kernels the plain layout is simplest. `nCtx` is 2538 as in the C++: 501 mel frames, the dataset row, up to 35 instrument rows, the initial token, 2000 tokens. |
| Threads | The CPU backend uses the performance cores (`hw.perflevel0.logicalcpu`) through `concurrentPerform`; there is no thread count option. Metal uses the GPU. |
| Backend choice | `LoadOptions.useGPU` (default true): Metal when `MTLCreateSystemDefaultDevice()` answers, the CPU otherwise. `backendName` is `"Metal"` or `"CPU"`. |
| Errors | `TranscriberError`, one case per `msl::Error`: `fileNotFound`, `invalidCheckpoint(String)`, `unsupportedArchitecture(String)`, `unsupportedCheckpointVersion(found: Int)`, `outOfMemory`, `contextOverflow`, `cancelled`, `invalidArgument(String)`, `internalError(String)`. `description` gives muscriptor.cpp's wording. |
| Logging | None. The library prints nothing. |
| Oracle | `app/Scripts/oracle/` (C++, built against the existing engine archives) dumps, for a checkpoint and a backend: the position table's first rows, the STFT of the fixture's first frames, the whole conditioning embedding of chunk 0, the prefill logits, the first sixteen decode steps' logits and argmaxes, every chunk's greedy token stream without prelude forcing, and the note lists of the `plain`, `prelude`, `bass` and `band` variants. Committed under the package's test fixtures for `small` (CPU and Metal) and `medium` (CPU and Metal). The generator stays in the repo with the muscriptor.cpp commit it was run against; once the submodule is gone, re-running it needs a checkout. |
| Fixtures | `fixture_3chunks_16k.wav` with its attribution, `tables.json` and `note_vectors.json` copied from the submodule into the package's test resources, so the package tests do not depend on it. |
| Checkpoints in tests | Looked for at `$NEURALSHEET_MODELS`, then `~/Library/NeuralSheet/models`, then `~/Library/NeuralNote/models`; a test that needs one skips with a message when it is absent. Never downloaded by a test. |
| Bench | `engine-bench`, an executable target: loads a checkpoint, transcribes the fixture on a backend, prints the backend, the real-time factor, the prefill time, the decode step mean and the note count. |
| The app | `TranscriptionEngine` wraps the package's `Transcriber` on the same dedicated thread with the same callbacks. `EngineError` becomes `load(TranscriberError)`, `transcribe(TranscriberError)`, `cancelled`, and `isUnsupportedVersion` reads the new case. `EngineNote` and `EngineUpdate` stay. `allGroups()` and `program(for:)` come from the package. |
| What goes | `Engine/nsheet_engine.h`, `Engine/nsheet_engine.cpp`, `Scripts/engine-smoke.sh`, `Scripts/engine_smoke.cpp`, the muscriptor lines of the bridging header, of `OTHER_LDFLAGS` and of `HEADER_SEARCH_PATHS`, the muscriptor half of `Scripts/build-engine.sh`, and the `ThirdParty/muscriptor.cpp` submodule. `build-engine.sh` keeps building `demucs.cpp` and the CI cache key stays. |
| Notices | `THIRD_PARTY_NOTICES.md` is a maintainer's file. The Swift port is a derivative of muscriptor.cpp (MIT) and its fixture audio is CC BY 4.0, so the package carries a `NOTICE` of its own naming both; the top-level file is left for the maintainer to update (its muscriptor.cpp entry stays true as the port's origin; ggml and PFFFT are no longer linked). |

## 3. The package

```
app/Packages/NeuralSheetEngine/
  Package.swift
  NOTICE                                   muscriptor.cpp (MIT), the fixture (CC BY 4.0)
  Sources/NeuralSheetEngine/
    Transcriber.swift                      the public API: load, transcribe, chunking, streaming
    Transcriber+Prelude.swift              prelude forcing and the per-chunk decode loop
    TranscribeOptions.swift                options, update, error
    Note.swift                             Note, InstrumentGroup, the public lookups
    Tokens/Vocabulary.swift                the MT3 ranges, eventFor, tokenFor, tieSectionTokenIds
    Tokens/OpenNoteTracker.swift           the decode state machine
    Tokens/NoteAssembler.swift             actions to notes, validate, trim, sort, closedIn
    Tokens/InstrumentGroups.swift          rows, forbidden ids, the lookups
    Tokens/InstrumentGroupTable.swift      the generated table (66 groups, 35 names)
    GGUF/GGUFFile.swift                    header, metadata, tensor infos, the mapped data
    GGUF/GGUFValue.swift                   the value types
    GGUF/Tensor.swift                      TensorInfo, dtype, F16 and F32 readback
    Model/Hparams.swift                    the metadata keys, the checks
    Model/ModelWeights.swift               named tensors per layer
    Model/PositionTable.swift              the sinusoidal table
    Model/Model.swift                      prefix assembly, prefill, decode, generate, masking
    DSP/STFT.swift                         reflect pad, window, vDSP real FFT, magnitudes
    DSP/ConditioningFrontEnd.swift         mel, log, projection, frame mask
    Backends/TransformerBackend.swift      the protocol, LayerInput
    Backends/CPU/CPUBackend.swift          the forward pass
    Backends/CPU/CPUKernels.swift          layerNorm, geluErf, softmax, residual
    Backends/CPU/CPUMatmul.swift           F16 GEMV (SIMD), F16 GEMM (vImage + cblas)
    Backends/CPU/CPUAttention.swift        scores, softmax, weighted sum over the cache
    Backends/Metal/MetalBackend.swift      device, queue, buffers, the forward pass
    Backends/Metal/MetalKernels.swift      pipeline states, dispatch helpers
    Backends/Metal/MetalShaderSource.swift the MSL source
  Sources/engine-bench/main.swift
  Tests/NeuralSheetEngineTests/
    Fixtures/audio/fixture_3chunks_16k.wav, README.md
    Fixtures/vectors/tables.json, note_vectors.json
    Fixtures/oracle/<size>-<backend>/…     see §6
    Support/Checkpoints.swift              where the weights are, skip helpers
    Support/OracleFixtures.swift           readers for the dumps
    <one test file per source file>
```

The C++ files map one to one; `docs/TOKENIZER.md`, `docs/MODEL.md` and `docs/API.md` in the
muscriptor.cpp repository describe the rules the Swift follows, and each Swift file's header
comment names the C++ file it ports.

## 4. The pipeline

Unchanged from the C++ (MODEL.md, "Pipeline"), restated with where each step runs:

```
16 kHz mono float32, the whole signal                     Transcriber
  split into 5 s chunks of 80 000 samples, the last zero-padded
  per chunk:
    STFT: reflect pad 1024, periodic Hann(2048) from the checkpoint,
          hop 160, vDSP real FFT, magnitudes             → [501][1025]     STFT (CPU, F32)
    mel = fb · mag, log(mel + eps), proj + bias, mask the frames past
          n_samples / hop (the 501st always)             → [501][dim]      ConditioningFrontEnd (CPU, F32)
    prefix = [cond, dataset row 1, instrument rows…, initial token, prompt…]
          + sinusoidal positions                         → [nNew][dim]     Model (CPU)
    N × pre-norm block, KV cache, out norm, LM head on the last row
                                                         → [vocab]         backend (CPU or Metal)
    logits[1393:] = −inf, forbidden ids = −inf, argmax; decode one token at a
    time until EOS or the budget                         → token ids       Model
    tokens → actions (tracker) → notes (assembler), the boundary and the
    prelude prompt from the tracker's open keys           → Note            Transcriber
  validate, trim overlaps, sort                          → [Note]          NoteAssembler
```

The attention block per layer, for `nNew` query rows over `nKV = nPast + nNew` cached rows:

```
h    = layerNorm(x) · w, + b                       [nNew][dim]
qkv  = h · Wqkvᵀ                                   [nNew][3·dim]   q | k | v, head_dim innermost
K[nPast..<nKV] = k, V[nPast..<nKV] = v             the cache, row per position
for each head: s = q_h · K_hᵀ / √head_dim          [nNew][nKV]
               s[i][j] = −inf where j > nPast + i  bottom-right causal
               p = softmax(s), o_h = p · V_h        [nNew][head_dim]
x   += concat(o_h) · Woᵀ
x   += gelu_erf(layerNorm(x) · Wupᵀ) · Wdownᵀ
```

after the last layer: `logits = layerNorm(x[nNew−1]) · Woutᵀ`.

## 5. Threading and the app

- `Transcriber` is a class, not thread-safe, one call at a time; it is created, used and dropped
  inside one `TranscriptionEngine.run`, on that run's thread, as the C bridge was. Nothing in the
  package touches the main actor; the types are `nonisolated` and the package sets no default
  isolation.
- The update callback runs synchronously on the transcribing thread, once per chunk and once at
  the end, with the same `newNotes` (one chunk late), `finalizedThrough` and `progress` as the C++.
  Returning `false` cancels; `transcribe` then throws `.cancelled`.
- `TranscriptionEngine.cancel()` sets its flag under the lock as today; the update callback reads
  it, so a cancel lands at the next chunk boundary.
- The Metal backend does its work on the run's thread through one `MTLCommandQueue` per
  `Transcriber`; `waitUntilCompleted` on each forward pass. Nothing here is near the render
  thread.
- `AppModel+Transcription`, `+RegionTranscription` and `+Stems` keep calling `transcriber.run`
  with the same arguments; only `failureReason` reads the new error shape.

## 6. Testing

The oracle, `app/Scripts/oracle/oracle.cpp`, is built by `oracle.sh` against
`build/engine/lib` and the submodule's headers, and writes one directory per checkpoint and
backend, `Tests/NeuralSheetEngineTests/Fixtures/oracle/<size>-<backend>/`:

| File | Contents |
|---|---|
| `hparams.json` | Every `Hparams` field, `nCtx`, the backend name, the checkpoint's file name and sha256 prefix, the muscriptor.cpp commit |
| `positions.f32` | The first 8 rows of the position table, `[8][dim]` |
| `stft.f32` | The first 8 frames of the fixture's chunk 0 magnitudes, `[8][1025]` |
| `cond.f32` | The conditioning embedding of chunk 0, `[501][dim]` |
| `prefill_logits.f32` | The masked logits after prefill of chunk 0 (initial token only, no instruments), `[vocab]` |
| `decode_logits.f32` | The masked logits of the first 16 decode steps, feeding the argmax each time, `[16][vocab]` |
| `tokens.json` | Per chunk, the greedy token stream with prelude forcing off and no selection (`Model::generate`) |
| `tokens_band.json` | Chunk 0's stream with the `band` selection (conditioning rows and the forbidden mask) |
| `notes_plain.json`, `notes_prelude.json`, `notes_bass.json`, `notes_band.json` | `Transcriber::transcribe` on the fixture, the four variants of TESTING.md, plus each variant's streamed updates (`finalizedThrough`, `progress`, the count of `newNotes`) |

The `.f32` files are raw little-endian float32; the JSON is flat. Tensors are dumped from the CPU
backend only; tokens and notes from both.

The ladder, in the order the model computes; a test names the fixture it reads:

| Test file | Needs | Checks |
|---|---|---|
| `VocabularyTests` | `tables.json` | Ranges, spot checks, `tieSectionTokenIds` cases |
| `InstrumentGroupsTests` | `tables.json` | The 66 representatives, the 35 names, `forbiddenTokenIds` cases, `conditioningRows` |
| `OpenNoteTrackerTests`, `NoteAssemblerTests` | `note_vectors.json` | Every vector's actions and notes, exactly (times within 1e-12) |
| `GGUFFileTests` | none, and a checkpoint | A GGUF written in the test (every value type, F16 and F32 tensors, alignment) reads back; the real file's tensor names and shapes; a non-GGUF and a wrong version fail with the right error |
| `PositionTableTests` | `positions.f32` | Against an fp64 evaluation to 1e-5, and against the oracle |
| `STFTTests` | `stft.f32` | Against a naive DFT on a synthetic signal to 1e-4 relative; reflect padding at both ends; DC and Nyquist; the oracle frames to 1e-4 of their scale |
| `ConditioningFrontEndTests` | `cond.f32` | The mask covers frame 500; the embedding against the oracle, max-abs within 1e-3 of the tensor's scale and cosine above 0.99999 |
| `CPUKernelsTests`, `CPUMatmulTests`, `CPUAttentionTests` | none | Each kernel against a scalar reference on random data: layer norm, GELU (erf, not tanh), softmax with a mask, GEMV and GEMM against `Double` accumulation, attention against a loop |
| `ModelTests` (CPU) | `prefill_logits.f32`, `decode_logits.f32` | Prefill and each decode step: the same argmax as the oracle (a disagreement is allowed only when the oracle's top two logits are within 0.05 of each other, and is counted), cosine above 0.999 |
| `ModelGenerateTests` (CPU) | `tokens.json`, `tokens_band.json` | Every chunk's stream identical up to the first counted near-tie, then at least the same length |
| `TranscriberTests` (CPU) | `notes_*.json` | The four variants' note lists identical (times within 1e-9); the streamed updates' `finalizedThrough` and `progress` sequences identical; an empty signal gives no notes and no calls; cancellation from the callback throws `.cancelled` after exactly one chunk; an unnamed group is `.invalidArgument`; a missing file is `.fileNotFound`; the tables' GGUF with `format_version` 2 is `.unsupportedCheckpointVersion` |
| `MetalBackendTests` | the same | `ModelTests`, `ModelGenerateTests` and `TranscriberTests` again on Metal, skipped where there is no device; CPU and Metal logits within the same cosine bound of each other |
| `MediumTests` | the medium checkpoint | `tokens.json` and `notes_prelude.json` on both backends, tagged slow, skipped without the file |

Tolerances follow muscriptor.cpp's reasoning: the fp16 gap on logits between runs is what decides
near-ties, and the token streams are the real test, because a wrong graph produces a different
stream within a handful of tokens.

The app: `xcodebuild` warning-free, `swift test` in both packages, the package built with
`xcodebuild -scheme NeuralSheetEngine -destination 'generic/platform=iOS'` and for the simulator,
and `engine-bench` run on `small` and `medium` on both backends with the numbers recorded in the
plan's final report.

## 7. Performance targets

Measured on this machine (M2 Pro, 8 performance cores) against `muscriptor_bench`'s numbers on an
M1 Pro (PERFORMANCE.md): `medium` decodes at 7.3 ms a step on ggml Metal and 13 ms on ggml CPU.
Targets: Metal under 15 ms a step and prefill under 0.5 s; CPU under 15 ms a step. The GEMV is
memory-bound (614 MB of F16 weights per token for `medium`), so a straightforward kernel that
streams the weights once is already close; nothing cleverer is planned.

## 8. Risks

- **A silent numerical slip.** The port is checked at every stage against the oracle, and the
  token-stream tests catch anything the tensor tests miss.
- **Near-ties.** Two backends that round differently can pick different tokens where the logits
  are within rounding of each other; the tests count these the way muscriptor.cpp's do rather than
  failing on them, and compare notes only up to the chunk where the first one happened.
- **Metal on the simulator.** The simulator has a Metal device but its performance is not
  representative; the tests only need it to exist.
- **Memory on iOS.** `medium` is 618 MB of weights and 499 MB of cache; `large` will not fit on a
  phone. The package does not decide sizes; the future iOS app will.
- **The submodule removal** changes the CI cache key's inputs (`.gitmodules`) and forces one
  cold `demucs.cpp` build; that is expected.
