# Instrument commands and region re-transcription — Design

A transcription's quality varies along the take: the model splits one part across several
programs, misses an instrument in one passage, or garbles a few bars while the rest is fine. Today
the only remedies are to fix notes one at a time or to run the whole take again and lose every
edit. This adds two remedies that work on the part that is wrong and leave the rest alone:

- **Whole-instrument commands** in the Edit tab: move every note of one instrument to another
  (which, when the other already has notes, is a merge), split an instrument at a pitch, or delete
  an instrument. Each is one undoable edit.
- **Region re-transcription**: mark a stretch of the timeline on the ruler, choose the instruments
  the model may use, and run the model on that stretch only. The result replaces the notes in the
  stretch as one undoable edit; the model's original output and the edits outside the stretch
  are untouched.

It builds on the editor design (`2026-09-19-midi-editor-design.md`) and the projects design
(`2026-09-21-projects-design.md`). Everything it does not mention is unchanged. Where it departs
from the NeuralNote inventory (`2026-09-17-neuralnote-feature-inventory.md`) it says so in §8.

## 1. Goals and non-goals

Goals

- Fix a wrong instrument assignment for a whole part in one action, undoable in one step.
- Re-run the model on one stretch of the audio, with a different instrument constraint if wanted,
  without losing the edits elsewhere or the ability to undo.
- Every rule of the new commands lives in `NeuralSheetCore` behind `swift test`; the app layer
  moves state in and out of the model and drives the engine.
- Nothing new in the project file. A project saved by this build opens in the previous one.

Non-goals

- Handles on the marked range, or editing its edges. To adjust, drag again.
- Streaming the region run's notes into the roll as they decode. The run lands at the end, as
  one batch; the band over the range shows progress.
- Keeping the model loaded between runs. The engine loads the checkpoint per run today (seconds
  for the large model) and still does. Reusing a loaded model across region runs is a later
  optimisation; the design here does not preclude it.
- Renaming an instrument. An instrument *is* its program; its name, chip and colour are the
  program's (`Instruments.info(forProgram:)`).
- Whole-instrument commands in the Transcribe tab. Editing is the Edit tab's (editor design §2).

## 2. Decisions

| Question | Decision |
|---|---|
| What is "merge A into B"? | Every note of program A is given program B. Same-instrument same-pitch overlaps that result are trimmed by the document's existing rule (editor design §4.4). |
| Where do the instrument commands live? | A right-click on a strip in the Edit tab opens a floating card at the pointer, like the roll's note card. The strip's face does not change. |
| How is the region chosen? | A drag across the ruler in the Edit tab. A click without a drag still seeks. Snapped to the grid when snap is on. |
| Which instruments does the region run decode with? | Chosen per run in a popup, preset to the instruments in the current mix, with an Automatic row. |
| What happens to the notes already in the range? | Notes that **start** inside the range are deleted; the run's notes that start inside it are inserted. A note that starts before the range and runs into it is kept whole. |
| How does the run land? | One `EditBatch` titled "Re-transcribe", through `AppModel.commit`. Cancel changes nothing. The model's raw notes (`transcription.rawNotes`) are not touched, so Revert to Transcription still means the original run. |
| Editing during a region run? | Locked: `canEdit` is false while the run is in flight. Playback keeps working. |

## 3. The note document (`NeuralSheetCore`)

### 3.1 New commands (`NoteDocument+Commands.swift`)

All four go through the existing `changing`, `delete` and `finished` helpers, so they clamp,
resolve same-pitch overlaps, and return an `EditBatch` the caller commits. The file is at 288
lines; the new commands go in a new `NoteDocument+InstrumentCommands.swift` and the region
replacement in `NoteDocument+Region.swift`, following the `+Extension` pattern.

| Command | Title | Rule |
|---|---|---|
| `reassign(program: Int, to destination: Int)` | "Change Instrument" | Every note whose program is `program` gets `destination`. Empty batch when there are none or `destination == program`. The merge is this command with a destination already in the mix. |
| `split(program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int)` | "Split Instrument" | With `sendingAbove`, every note of `program` whose pitch is **at or above** `pitch` gets `destination`; otherwise every note **below** `pitch` does. Empty batch when nothing qualifies or `destination == program`. |
| `deleteInstrument(program: Int)` | "Delete Instrument" | `delete` of every id whose program is `program`. |
| `replace(range: Range<Double>, with notes: [NoteEvent])` | "Re-transcribe" | Deleted: every existing note with `range.contains(startTime)`. Inserted: every note in `notes` with `range.contains(startTime)`, with fresh ids, its length kept even past `range.upperBound`. Notes in `notes` starting outside the range are dropped (they came from the context margin, §5.3). Then `finished`, so a new note against a kept note of the same instrument and pitch is trimmed at the seam. `mutating`, since it allocates ids; the app uses `replaceDocumentAndCommit`. |

The range is half-open: a note starting exactly at the upper bound belongs to what follows.

`reassign` to `NoteEvent.drumProgram` or from it follows `setProgram`'s existing rule: a drum
note given a melodic program becomes melodic and vice versa (editor design §4.3).

### 3.2 Tests (`NoteDocumentTests`)

- Reassign moves every note of the program and no other; a merge into a program with an
  overlapping same-pitch note trims the overlap; reassigning to itself is empty; undo restores.
- Split above sends exactly the notes at or above the pitch, split below exactly those below;
  the boundary pitch goes above; undo restores.
- Delete instrument removes every note of the program and nothing else; undo restores.
- Replace: a note starting before the range and ending inside it is kept whole; a note starting
  inside is deleted; a new note starting in the margin before the range is dropped; a new note
  starting inside and ending after the range keeps its length; a new note starting at the upper
  bound is dropped; a seam overlap on the same instrument and pitch is trimmed; an empty run on
  a range with notes deletes them; undo restores the document exactly.

## 4. `AppModel` integration

### 4.1 Instrument commands (`AppModel+Editing.swift` or a new `AppModel+Instruments.swift`)

```swift
func reassignInstrument(_ program: Int, to destination: Int)
func splitInstrument(_ program: Int, atPitch: Int, sendingAbove: Bool, to destination: Int)
func deleteInstrument(_ program: Int)
```

Each: guard `workspace == .edit`, `canEdit`, `program` is in `mixer.entries`; cancel any drag
(`dragCanceller`); commit the batch. After a reassign or split the selection is left as it is
(the ids do not change). After a delete the selection loses the deleted ids through
`applyDocument`, as today. No audition: these move whole parts, not a note.

`canEdit` becomes `state == .populated && document != nil && regionJob == nil` (§4.3).

### 4.2 The range (`EditorState`)

`EditorState.range: Range<Double>?`, transient. Not part of `ProjectContent`; a project opens
with no range.

```swift
func setRange(_ range: Range<Double>)   // clamped to 0..<duration; ignored if under 0.1 s
func clearRange()
```

Cleared by: `escapePressed` (after the drag cancel and before the deselect, see §6.3),
`resetTranscription` (which every clear, load and close goes through), and `transition(to:)`
leaving `.populated`. Undo and redo do not touch it.

### 4.3 The region run (`AppModel+RegionTranscription.swift`, new)

```swift
struct RegionJob: Equatable {
    var range: Range<Double>
    var groups: [InstrumentGroup]      // the run's constraint; empty is Automatic
    var sliceStart: Double             // seconds; the slice's first sample, range start less the margin
    var progress: Float = 0
    var cancelLatched = false
}
private(set) var regionJob: RegionJob?

func retranscribe(range: Range<Double>, groups: [InstrumentGroup])
func cancelRegionTranscription()
```

`retranscribe` refuses unless: `state == .populated`, `document != nil`, `regionJob == nil`,
`!jobActive`, `!transcriber.isRunning`, a checkpoint is installed (the same `modelSize` /
`installedPath` rule as `launchTranscriptionNow`), and the range is at least 0.1 s. It then:

1. Cancels any drag, dismisses the note card through the existing selection path (the
   selection is cleared), and sets `regionJob`.
2. Cuts the slice: `[max(0, start − margin), min(duration, end + margin))` in seconds, at
   16 000 samples a second from `source.mono16k`, with `margin = 2.0` (§5.3).
3. Calls `transcriber.run(modelPath:groups:samples16k:onUpdate:completion:)` with the slice.
   `onUpdate` hops each chunk's `progress` to the main actor with `Task { @MainActor in }` and
   returns true. There is no staging and no drain timer: the run's notes are not applied until
   it completes, and a chunk arrives once per 5 s of audio.
4. `completion` hops to the main actor into `handleRegionFinished`.

`handleRegionFinished(result)`:

- Guard `regionJob != nil`; a job cleared by a close or a clear ignores its completion, as the
  main run's does through `jobActive`.
- `.success(notes)`: shift every note by `sliceStart`, convert with `NoteEvent.init(engineNote:)`,
  run `mergeOverlappingNotesWithSamePitch`, then `document.replace(range:with:)` and
  `replaceDocumentAndCommit`. Select the inserted ids so the result can be auditioned, nudged or
  undone at once. Clear `regionJob`. The range stays marked.
- `.failure(.cancelled)`: clear `regionJob`; nothing else changes.
- `.failure(error)`: clear `regionJob`, then `showError("Transcription failed.", …)` with the
  same reason text `failureReason` builds for the main run (the unsupported-version wording
  included).

`cancelRegionTranscription`: guard `regionJob != nil`; set `cancelLatched`; `transcriber.cancel()`.

While `regionJob != nil`:

- `canEdit` is false: the roll's edit controller (§7), the inspector's fields, the strips' cards,
  the keyboard commands, Undo, Redo, Quantize, paste and the tab's other edits are inert. Today
  only the Edit menu's items are disabled on `canEdit`; the commands on `AppModel` guard on the
  workspace and the document. Each command that commits a batch gains `guard canEdit` so no
  path, menu or key or view, can commit while the run owns the range.
- `clear`, `clearTranscription`, `loadAudio`, `toggleRecord` and `launchTranscription` refuse,
  as they do for `jobActive`.
- Playback, seeking, zoom, the mix, the faders, mute and solo work.
- Switching to the Transcribe tab is allowed; the Edit tab is allowed back.
- Closing the project, opening another, New, and Quit go through `resetTranscription`, which
  cancels the engine and clears `regionJob`, so the completion is ignored. The save prompt's
  wording is unchanged; the run in flight is not saved and not mentioned.

The one `TranscriptionEngine` is shared by both paths. `isRunning` is the shared guard.

### 4.4 Project file

Unchanged. `RegionJob`, the range and the new commands add nothing to `ProjectContent`;
the batches they produce are ordinary `EditBatch`es, which the file already does not encode.

## 5. The region run's shape

### 5.1 Onset ownership

The range owns the notes that start in it, half-open `[start, end)`. Everything else keeps
whatever it has. This is what makes a sustained note across the range start survive intact,
and why a new note across the range end keeps its full length: the model saw the audio past the
end (§5.3) and its offset is the better one.

### 5.2 Seams

Two cases produce overlaps, both resolved by the document's existing same-instrument same-pitch
rule in `finished`:

- A kept note from before the range still sounding when a new note of the same pitch and
  instrument starts inside it: the kept note is trimmed to the new onset.
- A new note that runs past the range end into a kept note of the same pitch and instrument:
  the new note is trimmed to the kept note's onset.

Different instruments or pitches do not interact.

### 5.3 Context margin

The slice handed to the model is the range widened by `regionContextSeconds = 2` on each side,
clamped to the audio. The lead-in is what makes onset ownership work: a note sounding at the
range start is decoded with its onset in the lead-in and dropped, while a note that genuinely
starts at the range start is decoded with its onset there and kept. The tail lets the model place
the offset of a note that runs past the range end. A note still sounding at the slice end is
closed there, which the transcriber does for the end of any signal.

The slice's 5 s chunks start at the slice start, not at multiples of 5 s from the take's start.
That is fine, and sometimes the point: a passage the original run cut across a chunk boundary
is decoded whole.

### 5.4 Minimum run

The transcriber accepts any non-empty signal (a short tail is zero-padded) and the main run
insists on a second. With the margins, a 0.1 s range gives the model at least a second unless
the whole take is shorter, in which case there is no run to fix. `retranscribe` refuses a
range under 0.1 s and no other length.

## 6. UI

### 6.1 The strip card (`Sidebar/InstrumentCard.swift`, new)

In the Edit tab a right-click anywhere on a strip opens a floating card at the pointer on the
same `PopupMenuPresenter.showPanel(at:in:scale:)` and `popupSurface` the note card uses
(`RollEditController+Card.swift`), 236 px wide like the note card. In the Transcribe tab the
right-click does nothing. Left-click behaviour on the strip is unchanged.

The strip is SwiftUI and SwiftUI has no right-click gesture, so the strip gains a transparent
`NSViewRepresentable` overlay (`RightClickCatcher`, in `Controls/`) that forwards
`rightMouseDown` with the window point and passes every other event through
(`hitTest` answers itself only for a right button). It is installed only when the strip is given
an `onSecondaryClick` closure, which the `StripList` passes in the Edit tab and not otherwise.

The card, top to bottom, each row 22 px, label left in `Fonts.small` `textMuted`, control right,
as the inspector's rows:

| Row | Control | Action |
|---|---|---|
| Header | The instrument's name, uppercased, in the note card's header style, with its chip | — |
| Change to | Popup button, "—" until chosen, opening the instrument `MenuPanel` the inspector builds (instruments in the mix first with chips, a separator, the rest; the strip's own instrument omitted) | Choosing commits `reassignInstrument` and closes the card |
| Split at | `PitchField` (made internal, from `SelectionFields.swift`), preset to the midpoint of the instrument's pitch range rounded down; beside it a two-segment Above / Below `FlatButton` pair, Above on | Edits the draft only |
| Send to | Popup button like Change to, preset to "—" | Edits the draft only |
| — | **Split** label `FlatButton`, disabled at 0.38 until Send to is chosen | `splitInstrument` with the draft, closes the card |
| — | **Delete instrument** label `FlatButton` in `Theme.warn` text | `deleteInstrument`, closes the card |

The card is dismissed by the next click elsewhere, Escape, the tab changing, or the instrument
leaving the mix (the `StripList` re-renders without it; the presenter's `onDismiss` clears the
draft). The `MenuPanel` submenu is the presenter's `child`, as the inspector's is.

### 6.2 The ruler range (`Timeline/RulerView.swift`, `TimelineContainerView+Editing.swift`)

`RulerView` gains `onRange: ((Range<Double>) -> Void)?` beside `onSeek`, set by the container in
the Edit tab only. `mouseDown` records the anchor x; `mouseDragged` past 3 px (scaled) starts a
range from the anchor to the pointer, calling `onRange` on every move with both ends snapped when
`editor.snapEnabled` (through `TempoGrid`, the same snap the roll's draw tool uses) and clamped
to `0..<duration`; `mouseUp` without having passed the threshold is the seek it is today. A drag
that ends narrower than 0.1 s clears the range rather than marking a sliver.

The pointer over the ruler is the arrow in both tabs; the range shows on the first drag, no
cursor change.

### 6.3 Drawing the range (`PianoRollView+Editing.swift`, `WaveformView.swift`)

The range is a band over the roll's lanes and the waveform's bars, drawn in the Edit tab only:
`TimelinePalette.rangeFill` (`Theme.accent` at 0.10) the full height, with 1 px `rangeEdge`
(`Theme.accent` at 0.6) lines at both edges. In the roll it is a layer-backed subview like the
marquee's `MarqueeView`, below the marquee and the playhead, so notes read through it. In the
waveform it is drawn in `draw(_:)` after the bars. Both are positioned from `geometry` on every
layout, as the frontier and the playhead are.

While a region run is in flight, the band fills left to right with the job's progress in
`Theme.accent` at 0.22, so the roll shows how far the model has got.

Escape order in `escapePressed`: a drag in progress is cancelled; else a selection is cleared;
else the range is cleared. Two Escapes from a selection inside a range clear both.

### 6.4 The Re-transcribe button and popup (`Toolbar/EditToolbar.swift`, `Toolbar/RetranscribePopup.swift`)

The Edit toolbar's row (editor design §6.1) gains **Re-transcribe** as a labelled `FlatButton`
after Quantize, tooltip "Re-transcribe the marked range". Disabled at 0.38 with no range marked,
with no checkpoint installed, or while either kind of run is in flight.

Clicking opens a `MenuPanel` on the toolbar's `PopupMenuPresenter`, titled with the range as
`mm:ss.ddd – mm:ss.ddd` (`TimeFormat`), footer "Instruments the model may use":

- **Automatic** — a tick row; ticked when nothing else is. Choosing it clears the others.
- A separator, then every instrument currently in the mix as a tick row with its chip, ticked
  by default; then a separator and the remaining named groups and Drums, unticked. Multi-select,
  the panel stays open on a tick like the sidebar's instrument menu (`InstrumentMenu.swift`).
  Ticking any instrument unticks Automatic; unticking the last ticks it.
- A separator, then **Re-transcribe** as the last row, which calls
  `retranscribe(range:groups:)` and dismisses the popup.

The chosen set is remembered for the next popup within the session (`EditorState.retranscribeGroups`,
transient). A project opens with the mix's instruments preset again.

### 6.5 Progress

While `regionJob != nil` the Re-transcribe button is replaced in place by a `RegionProgress` view
that shares `TranscriptionProgress`'s metrics, pulse and bar: the caption "RE-TRANSCRIBING", the
150 × 3 bar, the percentage, the cancel cross. The cross calls `cancelRegionTranscription`; the
group dims at `cancelLatched`, as the status bar's does. `TranscriptionProgress`'s caption, pulse
and bar become parameters or a shared subview so the two do not drift; the status bar's own
group is unchanged and is not shown for a region run (the state is not `.processing`).

When the run lands, the inserted notes are the selection, the inspector shows their count, and
the Undo item reads "Undo Re-transcribe".

### 6.6 Keyboard

No new shortcut. Escape's order changes as §6.3. The `r` key in the Edit tab stays swallowed.

## 7. The edit controller

The controller lives exactly while the timeline is in Edit mode and in a window
(`syncEditController`); it does not come and go with `canEdit`, and this does not change that.
Instead its entry points gain the guard: `mouseDown`, `mouseDragged`, `mouseUp`, the right-click
that opens the note card, `insertNote` and the key handling return early when `model.canEdit` is
false, and `cursor(at:)` answers the arrow. A region run therefore leaves the controller in
place and inert for the duration, with no drag to cancel when it lands (one in progress was
cancelled at launch, §4.3 step 1).

## 8. Departures from the inventory

New behaviours with no NeuralNote counterpart, to be added to the departures list in `AGENTS.md`
and to `CHANGELOG.md` under Unreleased / Added:

- A right-click on an instrument strip in the Edit tab opens a card that changes, splits or
  deletes the whole instrument.
- A drag on the ruler in the Edit tab marks a time range; Re-transcribe in the Edit toolbar runs
  the model on that range alone, with its own instrument choice, and lands as one undoable edit.

Nothing existing changes: the Transcribe tab, the main run, the selection constraint before a
run, the sidebar's picker, the note card and the inspector are as they were.

## 9. Testing

`NeuralSheetCore` (`swift test`): §3.2 in full, plus `EditorState`-free math that can be
extracted: the slice bounds for a range and a duration (clamping at both ends), and the onset
filter (`replace` covers it).

App target, by hand, on a real take (there is no UI test target):

- Merge two piano programs into one from the strip card; undo brings both back.
- Split a piano at C3 sending below to Bass; the Bass strip appears with the low notes.
- Delete an instrument; the strip goes; undo brings it back with its fader as it was.
- Mark a range on the ruler with snap on; the ends land on grid lines. Click the ruler: seeks,
  range kept. Escape twice from a selection: selection then range go.
- Re-transcribe a range with Piano only; notes outside the range are untouched, a note across the
  range start is kept whole, the result is selected, Undo restores the previous notes exactly.
- Cancel a region run at the first chunk; nothing changes; the button comes back.
- Close the project during a region run; the welcome window appears; no crash, no dialog.
- Quit during a region run: the save prompt if dirty, then quit.
- Remove the checkpoint mid-session: the button disables on the next model poll.

## 10. Implementation order

1. `core:` the four document commands and their tests.
2. `app:` `EditorState.range`, `setRange` / `clearRange`, the Escape order, the clears.
3. `ui:` the ruler drag and the band in the roll and the waveform.
4. `app:` `AppModel+RegionTranscription.swift`, `canEdit`, the guards on the clears and loads,
   the close and quit paths.
5. `ui:` the Re-transcribe button, the popup, the progress group, the band's progress fill.
6. `app:` the instrument commands on `AppModel`.
7. `ui:` `RightClickCatcher`, the strip card, `PitchField` made internal.
8. `docs:` `AGENTS.md` departures, `CHANGELOG.md`, the doc comments that cite the editor design.

Each step is committed on its own once it builds warning-free and the tests pass.
