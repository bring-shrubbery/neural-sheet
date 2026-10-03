# Per-note confidence — Design

Spec: [issue #12](https://github.com/bring-shrubbery/neural-sheet/issues/12).

Every reviewer of every transcription tool says the same thing: the output needs cleaning up, and
nothing tells you where. The decoder knows. It picks each token by argmax over logits it could
just as well have turned into probabilities, and a note that was opened by a pitch token the model
gave 0.3 is a note worth a look. This carries that number out of the engine onto the piano roll,
into a selection command, and into two settings that drop short or unsure notes before they land.

Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A confidence per note, from the model's own token probabilities, at no measurable cost.
- Visible on the roll on request; readable on the card and in the inspector.
- One command that selects the doubtful notes; two settings that filter at the end of a run.
- The number survives a save and a reopen; old projects still open.

Non-goals

- A second colour scale (confidence rides the alpha the velocity already uses). The Score tab.
  Exports. A filter that touches notes already in the document.

## 2. Decisions

| Question | Decision |
|---|---|
| What the number is | For a melodic note: the geometric mean of the probabilities of the tokens that formed its onset event: the `velocity` token that set the on register, the `program` token if one was emitted since the last shift, and the `pitch` token. For a drum hit: the `drum` token's probability. Shift tokens are left out (they time the event, they do not assert it). Prompt (teacher-forced) tokens count as 1, so a note carried over a chunk boundary keeps the confidence it had when it opened. |
| Where it is computed | In `Model.generate`: after `argmax`, `exp(logit[next] − logsumexp(logits))`. Returned beside the tokens as `[Float]` of equal length. `OpenNoteTracker.feed(token:probability:)` keeps the probability of the current velocity and program registers and stamps `NoteAction.confidence` on `.start` and `.drumHit`. `TrackedNote` carries it to `Note.confidence`. |
| Cost | One pass over `vocabSize` floats per token on the CPU, where the logits already are. Measured against `Transcriber+Benchmark`; must be within noise. |
| `NoteEvent.confidence` | `Double?`, `nil` = not from the model. `confidenceOrSure` reads `confidence ?? 1`. Codable via `decodeIfPresent` / `encodeIfPresent`; no format-version bump (additive). `init(engineNote:)` copies it. |
| Edits | Every `NoteDocument` command that produces a new `NoteEvent` from an old one keeps the field (it is a struct copy; only `split` and `paste` need checking: split keeps it on both halves, paste keeps what the clipboard note had, insert sets `nil`). |
| Showing it | `GlobalSettings.showsConfidence` (default false) behind View → Show Confidence (⌥⌘C, checkmark toggle). `PianoRollView` shades alpha `0.25 + 0.75 × confidence` in both tabs when on; when off the current velocity rule stands. Confidence shading replaces the velocity term rather than multiplying it, so a loud doubtful note is as faint as a quiet one. |
| Card / inspector | A read-only "Confidence" row after Velocity: "72 %", "31 – 88 %" for a mixed selection, "—" when no selected note has one. |
| Select Doubtful Notes | Edit menu, after Deselect All, ⇧⌘D. Selects notes with `confidence < 0.5`, or shorter than the minimum length when that setting is on. Disabled outside the Edit tab or when it would select nothing. Goes through `setSelection`. |
| Settings | `GlobalSettings.minimumNoteLength: Double` (seconds, 0 = off; choices 0, 0.02, 0.03, 0.05, 0.075, 0.1) and `GlobalSettings.minimumConfidence: Double` (0 = off; 0.25, 0.5, 0.75). Two `Picker`s in a new "After transcription" section of the Model pane with a one-line footnote: "Dropped notes are gone; lower the setting and transcribe again to get them back." |
| Where the filter runs | `NoteFilter.apply(_:minimumLength:minimumConfidence:)` in `NeuralSheetCore`, pure. Called in `AppModel+Transcription` on `final` before `installDocument`, in `AppModel+Stems` on each stem's result before they merge, and in `AppModel+RegionTranscription` on the region's notes before the batch is built. Streaming (`rawNotes` during the run) is not filtered — the roll shows what the model is saying, the landing applies the setting. |

## 3. Engine (`Packages/NeuralSheetEngine`)

- `Model+Generate.swift`: `generate(...) -> (tokens: [Int32], probabilities: [Float])`. The prompt's
  entries are 1. `logSumExp` is a static helper beside `argmax`, written with a running max so it
  does not overflow.
- `OpenNoteTracker.swift`: `feed(token:probability:)` (the old `feed(token:)` stays as a wrapper
  passing 1 so existing tests compile). Registers gain `programProbability`, `velocityProbability`.
  `NoteAction.confidence: Float` defaults to 1.
- `NoteAssembler.swift` / `Note.swift`: `Note.confidence: Float` (default 1). Trimming and
  validation copy it.
- Tests: `OpenNoteTrackerTests` feed a hand-built stream `[shift p=1, program p=0.9, velocity p=0.8,
  pitch p=0.5]` and expect `(0.9 × 0.8 × 0.5)^(1/3)`; a drum token at 0.4 expects 0.4; a prompt
  prologue expects 1. `ModelGenerateTests` (if a tiny fixture model exists) or a unit test on
  `logSumExp` against `log(sum(exp))` for a known vector.

## 4. Core (`Packages/NeuralSheetCore`)

- `NoteEvent.swift`: the field, `confidenceOrSure`, the Codable keys.
- `NoteFilter.swift` (new): the pure filter. Tests: lengths at and around the threshold (a note of
  exactly the minimum length is kept), confidence at the threshold (kept), `nil` confidence never
  dropped, 0 thresholds change nothing.
- `NoteDocument+Commands.swift`: `split` copies, `insert` leaves `nil`; a test for each.
- `GlobalSettings.swift`: the three new fields with defaults and Codable fallbacks.
- `ProjectTranscription` round-trip test with and without the field.

## 5. App

- `AppModel+Transcription.swift`, `+Stems.swift`, `+RegionTranscription.swift`: the filter call
  at each landing, reading `settings`.
- `AppModel+Editing.swift`: `selectDoubtfulNotes()` and `canSelectDoubtfulNotes`.
- `NeuralSheetApp.swift`: the Edit and View menu items.
- `PianoRollView+Editing.swift` `drawNote`: the alpha rule, keyed off a `showsConfidence` flag the
  container passes down the same way `grid` is.
- `SelectionFields` / `RollEditController+Card.swift` / `SelectionInspector.swift`: the read-only
  row.
- `ModelSettingsView.swift`: the section. If the file passes ~400 lines, the section goes in
  `ModelSettingsView+Filters.swift`.

## 6. Changelog

"See how sure the model is about each note: View → Show Confidence shades the piano roll by it,
Edit → Select Doubtful Notes picks out the uncertain ones, and Settings → Model can drop notes that
are too short or too unsure as they arrive."

(Three clauses, one sentence, one feature; the convention's shape.)
