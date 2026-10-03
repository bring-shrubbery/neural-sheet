# Pitch curves — Design

Spec: [issue #17](https://github.com/bring-shrubbery/neural-sheet/issues/17).

The model's notes are steps; voices, strings and bent guitar notes are not. This measures, per
note, how far the sung or played pitch wanders from the note's nominal pitch, 10 ms at a time,
from the take's own audio, and carries that curve onto the roll and into the MIDI as pitch bend.
The model has no bend or pedal tokens (see the issue), so this is a signal measurement, scoped
to be reliable on a line and silent on a mix.

It builds on the MIDI editor design and the stem separation design (a vocal stem is the best
input). Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A per-note cents curve from the audio, with a confidence gate that prefers no curve to a wrong
  one; off the main thread; one undo step.
- Drawn on the roll; summarised on the card; written as bend on monophonic MIDI tracks.

Non-goals

- Pedal, polyphonic bend, MPE, playback following the curve, vibrato as notation.

## 2. Decisions

| Question | Decision |
|---|---|
| Storage | `NoteEvent.pitchCurve: [Float]?` — cents at 10 ms from the onset, length `⌊duration/0.01⌋`; `nil` = none. Codable `IfPresent`; `Equatable`/`Hashable` through the array. Project additive. |
| Measurement | For each frame (40 ms Hann window at 16 kHz, hop 10 ms, centred on the frame time) and each candidate offset `c ∈ {−200, −190, …, +200}` cents, the harmonic sum `S(c) = Σ_{h=1}^{5} G(h · f₀ · 2^(c/1200)) / h` where `G` is the Goertzel magnitude at that frequency and `f₀` the note's nominal frequency. The frame's deviation is the parabolic-interpolated argmax of `S`. Frame confidence = `S(best) / mean(S)`; a frame below 2.5 is marked unreliable. |
| Gate | A note keeps its curve when ≥ 70 % of its frames are reliable and the note is ≥ 60 ms; unreliable frames inside a kept curve are linearly interpolated from their neighbours. Then a 5-frame median filter. The curve's first value is used for frame 0 if frame 0 was unreliable. |
| Cost | 41 candidates × 5 harmonics × Goertzel over 640 samples ≈ 130 k multiply-adds per frame; a 3-minute vocal line (≈ 60 s of notes) is 6 000 frames ≈ 0.8 G flops, well under a second with `vDSP`. The tracker is written with `vDSP_dotpr` against precomputed cos/sin tables per (candidate, harmonic) for the window length, cached across notes of the same pitch. |
| Which notes | `isDrum == false` and `pitch` in 24…108 (outside that the harmonics leave the band or the window cannot resolve). |
| Threading | `AppModel+PitchTracking.swift`: `pitchJob: Task<Void, Never>?` modelled on `importJob`; `Task.detached` with the note list and `mono16k`; lands as one `EditBatch` through `setPitchCurves(ids: [NoteID: [Float]?])` (a new document command that replaces the field only). The guards that refuse during `regionJob` refuse during `pitchJob` too; a clear cancels it. |
| Curve lifetime | `NoteDocument` commands: `move` keeps the curve; `setPitch`, `resize`, `setLength`, `quantize(lengths: true)`, Snap to Scale, split and join set it to `nil` (join: the merged note has none); `setVelocity`, `setProgram` keep it. |
| Drawing | `PianoRollView.drawNote`: when `showsPitchCurves` and `rect.height ≥ 6`, a 1 px polyline through `(x_i, midY − cents_i / 100 × rowHeight)` sampled every max(1, frames/width) frames so a long note costs a path of at most its width in points; stroke colour the instrument's at alpha 1 lightened 30 %. In both tabs. |
| Setting | `GlobalSettings.showsPitchCurves` (default true), View → Show Pitch Curves. |
| Card / inspector | A read-only row "Pitch curve" with "±N ¢" (max |cents| over the selection's curves) or "—". |
| MIDI | In `MidiFileWriter`, per track: if no two notes overlap, emit at the track start `RPN 0 = 2 semitones` (CC 101=0, 100=0, 6=2, 38=0) then, per note with a curve, bend events at 10 ms ticks where `|Δcents| ≥ 5` from the last written value (14-bit value `8192 + cents/200 × 8191`, clamped), and `8192` at the note's end. Tracks with overlaps emit nothing new. |

## 3. Core

- `PitchTracker.swift` + `PitchTracker+Goertzel.swift`: `track(note:, mono16k:) -> [Float]?` and
  `track(notes:, mono16k:, isCancelled: () -> Bool) -> [NoteID: [Float]?]`.
- `NoteEvent.pitchCurve`; `mergeOverlappingNotesWithSamePitch` keeps the earlier note's.
- `NoteDocument+Commands.swift`: `setPitchCurves`, and the `nil`-ing in the commands listed.
- `MidiFileWriter+Bend.swift`.

Tests: a synthetic 440 Hz sine with a linear glide to 466 Hz over 0.5 s gives a curve rising to
≈ +100 ¢ (±10); a 6 Hz ±50 ¢ vibrato gives a curve with that excursion; white noise gives nil;
a note of 50 ms gives nil; the MIDI writer emits the RPN and bend events for a monophonic track
and none for an overlapping one; the document commands keep/drop as specified.

## 4. App

- `AppModel+PitchTracking.swift`, the View menu item, the Edit menu item, `drawNote`, the card
  and inspector row.

## 5. Changelog

"Edit → Track Pitch follows slides, bends and vibrato inside each note
from the audio, draws them on the piano roll, and exports them as pitch bend on monophonic MIDI
tracks."
