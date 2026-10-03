# Chord symbols — Design

Spec: [issue #16](https://github.com/bring-shrubbery/neural-sheet/issues/16).

The transcription has the notes; the harmony is implicit in them. This adds a chord list to the
project, a detector that fills it from the melodic notes, a lane over the piano roll and a line
over the score that show it, a card that corrects it, and `<harmony>` in the MusicXML.

It builds on the key detection design (`2026-09-27-key-detection-design.md`) for spelling and
the meter and tempo map design (`2026-10-03-meter-and-tempo-map-design.md`) for bars and beats.
Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A deterministic template detector over bars and half bars, key-aware, with slash basses.
- Chords as project state in seconds, shown in both tabs, edited in place, exported to MusicXML.

Non-goals

- Roman numerals, extensions past the seventh, chord playback, lead-sheet export.

## 2. Decisions

| Question | Decision |
|---|---|
| Types | `ChordQuality` enum (13 cases with `suffix` and `intervals: [Int]`), `ChordSymbol { root: Int, quality: ChordQuality, bass: Int? }` plus `.noChord`, `ChordEvent { seconds: Double, chord: ChordSymbol? }` (nil chord = N.C.). `ChordList = [ChordEvent]` sorted, each lasting until the next. |
| Where stored | `ProjectState.chords: [ChordEvent]` (default `[]`) and `ProjectState.chordsEdited: Bool` (so Detect can ask before replacing hand edits). Additive; no format bump. |
| Detector input | Melodic notes clipped to the window; weight = clipped duration × velocity/127; a pitch class profile `[12]`. Bass = the pitch class of the lowest note whose weight is at least 20 % of the heaviest in the window. |
| Scoring | For each root × quality template: `Σ weight(in-template pcs) − 0.6 × Σ weight(out-of-template pcs)`, normalised by total weight; +0.05 when every chord tone is in the key; +0.1 when the bass is the root; ties broken by the quality order in the enum (simpler first). A window whose total weight is below 5 % of the median bar's is N.C. |
| Segmentation | Score each bar as a whole and as two halves. If the best half-bar chords differ from each other and their mean score beats the whole bar's by 0.08, the bar splits. A half shorter than one beat (odd meters) never splits. Consecutive equal chords merge into one event. |
| Spelling | Roots and basses spelled from the key when there is one (flats in flat keys, sharps in sharp keys; the key's own accidentals preferred), else the sharp side for C/G/D-ish, flats otherwise using the `fifths` rule `MusicalKey` already has. "♯" / "♭" glyphs. |
| Detect buttons | `detectTempo()` gains the chord step after the key; Edit → Detect Chords (no key; ⇧⌘H is Humanize) runs only the chord step. Both ask "Replace the chord symbols?" when `chordsEdited`. |
| Lane | `ChordLaneView` (new, AppKit, in the document view stack between the ruler and the roll, 20 px, Edit tab only, zero height when the list is empty). Draws each symbol left-aligned at its x with a 4 px inset, clipped at the next event, in the ruler's font one size up, with a faint tick at its start. Click → card; double-click empty → add at the nearest beat (`grid.snap` of the click, or the nearest `.beat` line when snap is off); drag → move with the grid snap. The playhead layer already spans the stack; the lane is below it. |
| Card | `ChordCard` (SwiftUI in the floating panel the note card uses): Root menu (12), Quality menu (13), Bass menu (none + 12), Delete. Writes through `AppModel.setChord(at:_:)`, `removeChord(at:)`, `addChord(at:)`, `moveChord(from:to:)`. |
| Score | `ScoreDocument.chords: [(measure, units, text)]` built from the list through the grid; the renderer draws them above the top staff of each system, baseline 2 staff spaces above the highest thing in that column (ledger lines included), skipping a symbol that would overlap the previous one's text. `SheetMetadata.showsChords` (default true) in the Sheet card. PDF follows. |
| MusicXML | `<harmony>` before the first `<note>` at or after the chord's offset in the first visible part's measure, with `<root>`, `<kind>` (`major`, `minor`, `diminished`, `augmented`, `suspended-second`, `suspended-fourth`, `major-sixth`, `minor-sixth`, `dominant`, `major-seventh`, `minor-seventh`, `half-diminished`, `diminished-seventh`), `<bass>` when present, `<offset>` for mid-measure chords. N.C. writes `<kind>none</kind>` with text "N.C.". |

## 3. Core

- `ChordSymbol.swift`: the types, suffixes, spelling (`name(in key:)`).
- `ChordDetector.swift`: `detect(notes:, grid:, key:, duration:) -> [ChordEvent]`.
- `ScoreModel` gains `chords`; `MusicXMLWriter+Harmony.swift` writes them.
- `ProjectState` gains the two fields.

Tests: triads and sevenths from synthetic notes resolve to the right symbol; a C/E voicing gives
the slash; a bar of C then G splits; an empty bar is N.C.; spelling in F major gives B♭, in B
major A♯; MusicXML contains `<harmony>` with the right kind and offset; `ProjectState` round
trip with chords and without.

## 4. App

- `AppModel+Chords.swift`: `chords` (project state, marks edited), `detectChords()`, the four
  edit methods, `canDetectChords`.
- `AppModel+Tempo.swift`: the chord step in `tempoDetectionDidFinish`.
- `ChordLaneView.swift`, `ChordCard.swift` under `UI/Timeline/` and `UI/Timeline/Editing/`.
- `TimelineContainerView`: the lane in the stack, its height in the geometry (`rollY` moves by
  the lane's height in the Edit tab when the list is non-empty).
- `ScoreRenderer+Harmony.swift`, `SheetCard.swift` (the toggle), `ScorePDF` follows.
- `NeuralSheetApp.swift`: Edit → Detect Chords.

## 5. Changelog

"Chord symbols: Detect names the harmony from the notes, a lane above the piano roll and the
score show it, click a symbol to correct it, and the MusicXML export carries it."
