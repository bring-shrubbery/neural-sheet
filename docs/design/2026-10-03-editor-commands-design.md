# Editor commands — Design

Spec: [issue #14](https://github.com/bring-shrubbery/neural-sheet/issues/14).

The editor can move, resize, repitch, revoice and quantize, and every other correction is done a
note at a time. This adds the bulk commands a MIDI editor is expected to have (transpose by an
interval, velocity scaling and velocity from the audio, legato, join, split, humanize) and a
swing ratio on the grid. Each is a `NoteDocument` command returning an `EditBatch`, committed
through `AppModel.commit` like the rest.

It builds on the MIDI editor design (`2026-09-19-midi-editor-design.md`) and, for swing, on the
meter and tempo map design (`2026-10-03-meter-and-tempo-map-design.md`), which lands first.
Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- Seven commands on the selection-or-all, each one undo step, each a pure document function with
  tests.
- A swing ratio that the grid lines, snap and Quantize follow and the score ignores.

Non-goals

- Velocity lanes, groove templates, humanize settings, cross-instrument legato.

## 2. Decisions

| Question | Decision |
|---|---|
| Target set | `editor.selection` when non-empty, else every note; the same `selectionOrAll` helper `quantizeSelectionOrAll` uses. |
| Sheets | `By Interval…` and `Scale…` use an `NSAlert` with an accessory `NSStepper` + `NSTextField` (Dialogs.swift already builds alerts; a SwiftUI sheet would need the window plumbing the alerts avoid). The last value entered is remembered for the session. |
| Transpose | `document.move(ids, deltaSeconds: 0, deltaSemitones:)` already exists and clamps to 0…127; drums are excluded by filtering `isDrum` out of the set first. The four fixed items call it with ±1 / ±12. |
| Velocity scale | `setVelocities(_ ids:, transform: (Int) -> Int)`: a general per-note velocity map, used by Scale, From Audio and Humanize alike. |
| From Audio | `OnsetLoudness.measure(mono16k:, atSeconds:, window: 0.05) -> Double` (dB RMS, floor −80) in Core; the mapping is linear from the min to the max dB among the affected notes onto 24…127; a set whose min equals its max gets 100. Computed on the main actor: it is O(notes × 800 samples). |
| Legato | For each affected note, the successor is the earliest note of the same program whose start is strictly after this note's start (any pitch, selected or not). New end = successor start. Notes are considered in start order; a note with no successor is unchanged. Minimum resulting length is `Note.minimumDuration` (10 ms), so two notes at the same start do not produce a zero-length note. |
| Join | Sort affected notes by (program, pitch, start); walk runs; merge while `next.start − current.end ≤ max(0.05, snapEnabled ? grid.step : 0)`. The merged note keeps the first's id, velocity and confidence; the others are deleted. |
| Split | Affected notes with `start < playhead < end` and both halves ≥ 10 ms. The first half keeps the id; the second is inserted with a new id. The selection becomes all halves. Afterwards `auditionSelection()` is not called. |
| Humanize | `SystemRandomNumberGenerator`; start Δ uniform in ±0.012 s (clamped at 0), velocity Δ uniform integer in ±8, clamped 1…127; the end moves with the start. Implemented as `move` per note plus `setVelocities`, folded into one batch. |
| Swing | `TempoGrid.swing: Double` (0.5…0.75, default 0.5), in the project. `lines`, `snap`, `snapDown` apply it: for a division of an eighth or a sixteenth, the odd-indexed division within each beat (eighth) or each eighth (sixteenth) is placed at `pairStart + swing × pairLength` instead of the midpoint. Triplet divisions, bar, half, quarter and thirty-second ignore it. The score's `unitNotes` and the MusicXML writer use a copy of the grid with `swing = 0.5`. |
| Swing control | `GridControls` gains a SWING field in the TEMPO group's style: a numeric field 50…75 with the `%` suffix and a double-click reset to 50; disabled when the division has no swing. |
| Menu | Edit menu, after Snap to Scale: Transpose ▸ (5 items), Velocity ▸ (Scale…, From Audio), then Legato ⌘L, Join Notes ⌘J, Split at Playhead ⌘T, Humanize ⌥⌘H. All disabled outside the Edit tab or without a document; From Audio also without audio; Split also when no note spans the playhead. |
| Keys | ⌘L, ⌘J, ⌘T, ⌥⌘H are free (the Loop key is a bare `l`; Transcribe has no key). They are menu shortcuts only, so `KeyboardShortcuts.swift` is untouched. |

## 3. Core

### `NoteDocument+BulkCommands.swift` (new)

```swift
extension NoteDocument {
    public func setVelocities(_ ids: Set<NoteID>, transform: (Int) -> Int) -> EditBatch
    public func legato(_ ids: Set<NoteID>) -> EditBatch
    public func join(_ ids: Set<NoteID>, gap: Double) -> EditBatch
    public func split(_ ids: Set<NoteID>, at seconds: Double) -> (batch: EditBatch, halves: Set<NoteID>)
    public func humanize(_ ids: Set<NoteID>, timing: Double, velocity: Int,
                         using generator: inout some RandomNumberGenerator) -> EditBatch
}
```

Tests (`NoteDocumentBulkCommandTests`): legato against a successor on another pitch, no
successor, successor at the same start; join merges a run and leaves a gap wider than the limit;
join keeps the first note's velocity and confidence; split produces two halves with the right
ids and skips notes the playhead does not cross; humanize with a seeded generator is
deterministic and stays within bounds; `setVelocities` clamps.

### `OnsetLoudness.swift` (new)

`measure(mono16k:atSeconds:window:)` and `velocities(forOnsets:mono16k:) -> [Int]` (the mapping).
Tests on a synthetic signal with two onsets 20 dB apart: the quiet one gets 24, the loud one 127;
a single onset gets 100.

### `TempoGrid`

`swing`, its Codable default, and the placement in `lines` / `snap` / `snapDown`. Tests: swing
0.5 reproduces today's lines; swing 2/3 on an eighth grid puts the off-beat at 2/3 of the beat;
a sixteenth grid swings within each eighth; triplets unchanged; `snap` of a point near a swung
line lands on it.

## 4. App

- `AppModel+BulkEditing.swift` (new): `transposeSelectionOrAll(semitones:)`,
  `scaleVelocity(percent:)`, `velocityFromAudio()`, `legatoSelectionOrAll()`,
  `joinSelectionOrAll()`, `splitAtPlayhead()`, `humanizeSelectionOrAll()`, `setSwing(_:)`, and the
  `can…` flags the menu reads.
- `Dialogs.swift`: `presentNumber(title:label:range:initial:suffix:on:completion:)` — the stepper
  alert; `AppModel+BulkEditing` calls it for By Interval… and Scale…
- `NeuralSheetApp.swift`: the menu items.
- `GridControls.swift`: SWING (if the file passes ~400 lines, the key controls move out first,
  as the tempo-map design already allows).

## 5. Changelog

"Clean up a transcription in bulk from the Edit menu: transpose by an interval, scale the
velocity or take it from the audio, make a line legato, join or split notes, humanize a
passage, and swing the grid from the Edit toolbar."
