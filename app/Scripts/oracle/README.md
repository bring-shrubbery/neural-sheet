# The oracle

`oracle.cpp` dumps what the C++ engine, `muscriptor.cpp`, computes on the audio
fixture, and `oracle.sh` runs it once per checkpoint and backend. The Swift
`NeuralSheetEngine` tests compare against those dumps stage by stage, so the port
is checked against the C++ engine's real numbers rather than against itself.

The dumps live in the package, tracked:

```
app/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures/oracle/
  small-cpu/  small-metal/  medium-cpu/  medium-metal/  large-cpu/  large-metal/
```

The tests read the tensors (`positions.f32`, `stft.f32`, `cond.f32`,
`prefill_logits.f32`, `decode_logits.f32`, `decode_steps.json`) from the `-cpu`
directories only, and the tokens and the notes from the directory matching the
backend they are running on. The tensors are written for both backends anyway,
because they cost a second and make a Metal-only divergence easy to locate.

## The files

Every directory holds the same set, for one checkpoint on one backend.

| File | Contents |
|---|---|
| `hparams.json` | Every `msl::Hparams` field, the `n_ctx` the dump used (2538), the backend (`CPU` or `Metal`), the checkpoint's file name and the muscriptor.cpp commit |
| `positions.f32` | Rows 0…7 of `Model::positionEmbeddings()`, `[8][dim]` |
| `stft.f32` | Frames 0…7 of `model.stft().magnitudes(chunk0)`, `[8][1025]` |
| `cond.f32` | `model.encodeAudio(chunk0)`, `[501][dim]` |
| `prefill_logits.f32` | The masked logits after `reset()` and `prefill(cond, 501, {initial_token_id})`, `[vocab_size]` |
| `decode_steps.json` | `{"fed", "argmax"}`, 16 entries each: step *s* feeds the argmax of the previous logits (the prefill's at step 0) and records the argmax of the logits it returns |
| `decode_logits.f32` | Those 16 steps' masked logits, `[16][vocab_size]` |
| `tokens.json` | `{"chunks": [[…], […], […]]}`: per chunk, `reset()`, `encodeAudio`, `generate(cond, 501, 2000, 1)`, unconditional, EOS included |
| `tokens_band.json` | `{"instruments", "chunk0"}`: the same on chunk 0 with the `band` selection installed through `setInstrumentRows` and `setForbiddenTokens` |
| `notes_plain.json`, `notes_prelude.json`, `notes_bass.json`, `notes_band.json` | `Transcriber::transcribe` over the whole fixture, the four variants of muscriptor.cpp's `docs/TESTING.md`: plain (no forcing, no selection), prelude (forcing), bass (forcing + `electric_bass`), band (forcing + `distorted_electric_guitar`, `synth_lead`, `electric_bass`, `drums`, `voice`). Each holds the note list and the per-chunk streamed updates (`finalized_through`, `progress`, the count of `new_notes`) |

`chunk0` is the fixture's first 80 000 samples. The `.f32` files are raw
little-endian float32 with no header; their shapes come from `hparams.json`. In
the JSON, note times are written with `%.17g` and the float hyperparameters with
`%.9g`, both of which round-trip exactly.

## CPU and Metal

The two backends are not bit-identical: ggml's Metal matmul rounds some inputs
to half precision, so `prefill_logits.f32` and `decode_logits.f32` differ
between a `-cpu` directory and its `-metal` one. Everything decided by a
comparison rather than by a bit pattern agrees exactly on this fixture, for both
sizes: `decode_steps.json`, `tokens.json`, `tokens_band.json` and all four
`notes_*.json` are byte-identical between `small-cpu` and `small-metal`, and
between `medium-cpu` and `medium-metal`, and between `large-cpu` and `large-metal`, so no chunk diverges. (`positions.f32`,
`stft.f32` and `cond.f32` are identical too — the front-end runs on the host in
fp32 on either backend.) The tests still read the directory for the backend they
run on, so a future divergence shows up as a failure in one backend only.

## Regenerating

```sh
app/Scripts/oracle/oracle.sh
```

It needs:

- A checkout of `muscriptor.cpp` at commit
  `0ef3b14e6e39e7296a0a0202ad07b41de3e99649` under `app/ThirdParty/`, and
  `app/build/engine/lib` built from it by `app/Scripts/build-engine.sh`. The
  script builds the archives only when they are missing.
- `muscriptor-small-f16.gguf` and `muscriptor-medium-f16.gguf`, looked for under
  `$NEURALSHEET_MODELS`, then `~/Library/NeuralSheet/models`, then
  `~/Library/NeuralNote/models`.
- The fixture WAV, taken from the package's `Fixtures/audio/` copy, or from the
  submodule's `testdata/audio/` when that copy is not there.

Once the submodule is gone from the tree, point the script at a checkout of it
elsewhere. `NEURALSHEET_ENGINE_ROOT` is the `app` directory that holds
`ThirdParty/muscriptor.cpp` and `build/engine/lib`;
`NEURALSHEET_MUSCRIPTOR_COMMIT` overrides the commit recorded in `hparams.json`
when `git` cannot answer for that checkout:

```sh
NEURALSHEET_ENGINE_ROOT=/path/to/a/checkout/app \
NEURALSHEET_MUSCRIPTOR_COMMIT=0ef3b14e6e39e7296a0a0202ad07b41de3e99649 \
  app/Scripts/oracle/oracle.sh
```

The dumps in the repository were made with exactly that, from
`/Users/antoni/Projects/neural-sheet/app`.

## The benchmark

`swift run -c release engine-bench <checkpoint.gguf> <cpu|gpu>` runs the Swift
engine over the same fixture the oracle uses (15 s, three chunks) and prints both
the whole-signal number a caller feels and the per-phase breakdown an
optimisation is tuned against. It is not part of the oracle, but it is the other
half of what the checkpoints are kept installed for, so its numbers live here.

Measured on an Apple M2 Pro, 8 performance cores, 19 GPU cores, `-c release`.
`real-time` is the whole transcription — the conditioning, the chunk loop, the
note assembly and every token — against the 15 s of audio, so above 1× is faster
than playback. The phase columns are measured warm, after that full
transcription, over 200 decode steps on chunk 0, so they time the kernels rather
than the first touch of a memory-mapped weight.

The `ggml` columns are the C++ engine over the same fixture, from the benchmark in
muscriptor.cpp's `cpp/bench`, run in the same session on the same machine so that the
two columns are comparable to each other. Every cell is the best of two to four runs.

| Checkpoint | Backend | Real-time | Prefill | Decode p50 | ggml real-time | ggml prefill | ggml decode p50 |
|---|---|---|---|---|---|---|---|
| `small` | Metal | 4.65 × | 48 ms | 2.41 ms | 2.95 × | 62 ms | 2.82 ms |
| `medium` | Metal | 1.90 × | 138 ms | 5.69 ms | 1.34 × | 125 ms | 7.85 ms |
| `large` | Metal | 0.54 × | 538 ms | 20.91 ms | 0.45 × | 433 ms | 24.20 ms |
| `small` | CPU | 1.51 × | 185 ms | 6.43 ms | 1.55 × | 1057 ms | 3.77 ms |
| `medium` | CPU | 0.62 × | 438 ms | 16.02 ms | 0.48 × | 2878 ms | 10.30 ms |
| `large` | CPU | 0.18 × | 1392 ms | 63.11 ms | 0.14 × | 12385 ms | 44.26 ms |

The decode step is memory-bound — one pass over every F16 weight per token, roughly
the checkpoint's own size, 200 MiB for `small`, 590 for `medium` and 2.6 GiB for
`large` — so the p50 tracks the size. On Metal it repeats within a few percent from run
to run, and the three Metal rows above were taken at a low enough load to be trusted.

**The six CPU cells were not.** They record the quietest run of a session in which a
browser held a core at 80 % throughout (load average 4 to 8), and the CPU columns move
a great deal with that: on a quiet machine the same builds measure a decode step of
5.49 ms and 11.71 ms for our `small` and `medium` against ggml's 3.61 and 9.16, and a
ggml CPU prefill of 550 ms and 1720 ms rather than the 1057 and 2878 recorded — about
half. ggml's CPU prefill is the most load-sensitive number here; ours moves least,
because ggml's threads spin and hold their cores where ours go through
`concurrentPerform`. Prefill is a single burst over 501 frames and spreads more than
the decode columns again. The `large` CPU row was only ever measured under that load,
for both engines, so it is the least comparable of the six.

Against the targets of the performance pass — within 15 % of ggml on every Metal
row and within 25 % on CPU decode — Metal meets all three decode targets and
beats ggml on every one of them, `small` and `medium` meet their prefill targets
(`small` beats ggml, `medium` is 10 % behind it at 138 ms against a 145 ms
target), and `large`'s prefill misses at 538 ms against a target of 480 and
ggml's 433: what is left there is `matmul_tiled_f16`, which reaches 3.0 TFLOP/s
of this device's 6.8. On the CPU `medium` meets its 12.6 ms target on a quiet
machine and `small` misses its 4.8 ms one at 5.49; the CPU prefill is five to nine
times faster than ggml's on the rows as recorded, and three to four times on a quiet
machine for `small` and `medium` (550 and 1720 ms for ggml against our 185 and 438;
`large` was never measured quiet), because ours is a blocked GEMM through
`cblas_sgemm` and ggml's is not.

