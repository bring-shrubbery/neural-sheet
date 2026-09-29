# The oracle

`oracle.cpp` dumps what the C++ engine, `muscriptor.cpp`, computes on the audio
fixture, and `oracle.sh` runs it once per checkpoint and backend. The Swift
`NeuralSheetEngine` tests compare against those dumps stage by stage, so the port
is checked against the C++ engine's real numbers rather than against itself.

The dumps live in the package, tracked:

```
app/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures/oracle/
  small-cpu/  small-metal/  medium-cpu/  medium-metal/
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
between `medium-cpu` and `medium-metal`, so no chunk diverges. (`positions.f32`,
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
