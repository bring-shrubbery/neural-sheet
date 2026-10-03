# Time signature and tempo changes — Design

Spec: [issue #13](https://github.com/bring-shrubbery/neural-sheet/issues/13).

`TempoGrid` is one BPM, one downbeat and `beatsPerBar = 4`, and everything that thinks in bars
(snap, the ruler, the score, MusicXML, MIDI) reads those three. A waltz gets bars of four; a take
that slows down drifts off the grid by its last chorus. This replaces the single tempo with a
list of segments, each starting on a bar line with a tempo and a time signature, puts the
conversions in one place, and teaches Detect to track beats through the take rather than
averaging it.

It builds on the tempo design (`2026-09-27-tempo-detection-design.md`), the score designs and
the MusicXML export design. Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A meter and a piecewise-constant tempo per project, with exact seconds ⇄ beats ⇄ bar.beat
  conversions used by every consumer.
- Set by hand on the toolbar and the ruler; found by Detect as a beat track folded into segments.
- Old projects open unchanged; the score and both exports show the same bars a DAW would.

Non-goals

- Tempo ramps, mid-bar meter changes, pickup bars, swing. Undo for grid changes (the grid is
  project state, as the BPM and key are today).

## 2. Decisions

| Question | Decision |
|---|---|
| The unit of tempo | Quarter-note BPM throughout, as MIDI and the current field have it. A bar of `n/d` lasts `n × 4/d` quarter beats; 6/8 at "120" means 120 quarters, 80 dotted quarters, and the field says so in its tooltip. The score's metronome mark prints the beat unit the meter implies (♩ for x/4, ♩. for 6/8-type compound). |
| Representation | `TimeSignature { numerator: 1…32, denominator: 1,2,4,8,16,32 }` and `GridSegment { startBar: Int, bpm: Double, timeSignature: TimeSignature }`. `TempoGrid { offsetSeconds, division, segments: [GridSegment] }` with `segments[0].startBar == 1` always, sorted, bars strictly increasing. `bpm` stays as a computed property (segment 1's, get and set) so the one-tempo code paths keep reading. |
| Before bar 1 | Segment 1 extends backwards: bar 0, −1 … at its tempo and meter, as today. |
| Conversions | Everything goes through two functions on `TempoGrid`: `quarterBeats(atSeconds:)` and `seconds(atQuarterBeats:)`, piecewise linear over the segment boundaries, which are themselves computed once per grid value into a cached `[(startBeats, startSeconds)]` table (the struct is small; the table is rebuilt on mutation). `barBeat(at:)`, `snap`, `snapDown`, `lines(from:to:)`, `barStart(bar:)` and `bar(atQuarterBeats:)` are written over them. |
| Grid lines | `.bar` at bar starts, `.beat` at every `4/d` quarter beats within a bar (so 6/8 shows six), `.division` at the chosen division counted in quarter notes from the bar start, so the sixteenth grid stays a sixteenth in every meter. A division that does not fit a bar (a triplet-eighth division in 7/8) restarts at each bar line. |
| Export offset | `exportStartOffsetSeconds` keeps its meaning (bar lines land on the file's) using segment 1's bar length. |
| Project file | `TempoGrid`'s `Codable` writes `offsetSeconds`, `division`, `segments`. Decoding without `segments` builds one from `bpm` (old files). `ProjectState.currentFormatVersion` is unchanged; the change is additive. `exportTempo` in `ProjectState` is already the grid's bpm and follows. |
| Meter detection | Between 3/4 and 4/4 only, and only when the contrast is clear; 2/4 cannot be told from 4/4 by accent and compound meters need a different beat level. The issue's list is narrowed to this; the user sets the others. |
| Beat tracking | Ellis's dynamic-programming tracker over the existing 200 Hz onset envelope: the autocorrelation tempo gives the target period, the score for a beat at frame `t` is `envelope[t] + max over previous beats of (score[p] − α·(log(t−p) − log period)²)`, α = 680 at this frame rate (librosa's tightness 100 scaled), backtracked from the best final frame. Local period: the target period is re-estimated over a sliding 8 s autocorrelation window so a long ritardando is followed rather than fought. |
| Beats to a map | Downbeat phase as today, now over `n` candidates. Bars from the beat list; per-bar BPM = `60 × beatsPerBar / barSeconds`; bars merge into the running segment while within 2 % of its first bar's BPM; each segment's BPM is the median of its bars rounded to 0.1; the first segment's start is the first downbeat (the new offset). Fewer than two bars → the single estimate as today. |
| Detect's confirmation | If the current grid has more than one segment or a meter other than 4/4, Detect asks "Replace the tempo map?" through the standard dialog before running. |
| Toolbar | `GridControls` gains TIME: a numerator menu (1…32, the common ones first) and a denominator menu (1, 2, 4, 8, 16) after the TEMPO field. TEMPO, TIME and Tap act on the segment under the playhead. BEAT 1 AT keeps moving the whole map. |
| Ruler | A marker (a small flag in the ruler's accent colour, labelled "90" or "90 · 3/4") at each segment start after the first, in both tabs. Right-click on the ruler opens a floating card (the note card's style): the segment's bar, TEMPO field, TIME menus, and *Add Tempo Change at Bar N* when the pointer's bar is not already a segment start, or *Remove Tempo Change* when it is one after the first. |
| Score | `ScoreDocument` measures carry `lengthUnits`, `timeSignature?` (set when it differs from the previous measure's, and on the first) and `tempoMark?` (set on the first measure and at each tempo change). The system layout reads the per-measure length instead of `barUnits`. |
| MusicXML | `<attributes><time>` on the first measure and at each change; `<direction>` with `<metronome>` and `<sound tempo>` at the first measure and at each tempo change. `divisions` stays 24 per quarter. |
| MIDI | `0xFF 0x58` at tick 0 and at each meter change; `0xFF 0x51` at tick 0 and at each tempo change; note ticks are `quarterBeats × 960` through the map, so a DAW's bars match the score's. |

## 3. Core (`Packages/NeuralSheetCore`)

### `TempoGrid.swift` → `TempoGrid.swift` + `TempoGrid+Map.swift` + `TimeSignature.swift`

```swift
public struct TimeSignature: Equatable, Hashable, Codable, Sendable {
    public var numerator: Int, denominator: Int
    public static let common = TimeSignature(numerator: 4, denominator: 4)
    public var quarterBeatsPerBar: Double { Double(numerator) * 4 / Double(denominator) }
    public var beatLength: Double { 4 / Double(denominator) }        // in quarter beats
    public var label: String                                            // "3/4"
    public static let presets: [TimeSignature]                          // 4/4 3/4 2/4 6/8 5/4 7/8 9/8 12/8
}

public struct GridSegment: Equatable, Codable, Sendable {
    public var startBar: Int, bpm: Double, timeSignature: TimeSignature
}

public struct TempoGrid {
    public var offsetSeconds: Double, division: GridDivision
    public private(set) var segments: [GridSegment]               // invariant kept by the mutators
    public var bpm: Double { get set }                            // segment 1
    public var timeSignature: TimeSignature { get set }           // segment 1

    public func segmentIndex(atBar: Int) -> Int
    public func segment(atSeconds:) -> GridSegment
    public func quarterBeats(atSeconds:) -> Double
    public func seconds(atQuarterBeats:) -> Double
    public func barStart(bar: Int) -> Double                      // seconds
    public func barBeat(at seconds:) -> (bar: Int, beat: Int)
    public mutating func setTempo(_ bpm: Double, atBar:)          // on the segment covering the bar
    public mutating func setTimeSignature(_:, atBar:)
    public mutating func addChange(atBar:)                        // copies the covering segment
    public mutating func removeChange(atBar:)                     // not bar 1
    public mutating func replaceMap(_ segments: [GridSegment], offsetSeconds:)
}
```

`snap`, `snapDown`, `lines(from:to:division:)`, `barBeatLabel`, `exportStartOffsetSeconds`,
`clampedBpm` keep their signatures.

Tests: round trips `seconds → beats → seconds` across three segments; bar.beat at and just
before boundaries; lines in 3/4 and 6/8 (count per bar, kinds); snap across a tempo change;
Codable of an old `{bpm, offsetSeconds, division}` payload; invariants after add/remove.

### `TempoEstimator.swift` → `+ BeatTracker.swift`, `+ TempoMapBuilder.swift`

- `BeatTracker.track(envelope:, bpm:) -> [Double]` (beat times in seconds).
- `MeterEstimator.estimate(envelope:, beats:) -> TimeSignature?` (3/4 vs 4/4, nil when unclear:
  the better candidate's downbeat contrast must exceed the other's by 25 %).
- `TempoMapBuilder.build(beats:, downbeatIndex:, timeSignature:) -> (offset: Double, segments: [GridSegment])`.
- `TempoEstimate` gains `segments` and `timeSignature?`; `estimate(mono16k:)` fills them.

Tests on synthetic click tracks: constant 120 → one segment at 120.0; 120 for 8 bars then 90 →
two segments at bars 1 and 9; a linear slowdown → segments monotonically decreasing; a 3/4
accented click → 3/4, a flat click → nil.

### `ScoreModel.swift`, `ScoreSystemLayout.swift`, `MusicXMLWriter*.swift`, `MidiFileWriter.swift`

- `ScoreMeasure` gains `lengthUnits`, `timeSignature: TimeSignature?`, `tempo: Double?`.
- `MusicXMLWriter.unitNotes` converts through `grid.quarterBeats(atSeconds:)`;
  `segments(_:from:to:barLength:)` becomes `segments(_:measures:)` taking the measure table;
  `measureSpan` builds the table from the grid's bars over the notes' span.
- `measureIndex(atSeconds:grid:)` / `seconds(atMeasure:units:grid:)` go through the table.
- `MidiFileWriter.write` takes the grid (it has the bpm today) and emits the meta events; the
  seconds-to-ticks helper becomes `grid.quarterBeats(atSeconds:) × ticksPerQuarter`.

Tests: a 3/4 score has 72-unit measures and `<time>3/4`; a map with a change at bar 5 writes a
second `<time>`/`<sound>` and a second `0x51`; the existing writer tests still pass (4/4, one
segment).

## 4. App

- `AppModel+Editing.swift`: `setGridBpm` → tempo at the playhead's bar; `setTimeSignature(_:)`;
  `addTempoChange(atBar:)`, `removeTempoChange(atBar:)`, `setTempo(_:atBar:)`,
  `setTimeSignature(_:atBar:)`; `tap()` routes to the playhead's segment.
- `AppModel+Tempo.swift`: the confirmation, `replaceMap` on landing, and `detectKey()` after.
- `GridControls.swift`: TIME menus. If the file passes ~400 lines the key controls move to
  `KeyControls.swift`.
- `RulerView.swift`: markers (`drawTempoMarkers`) and the right-click → `RulerTempoCard.swift`
  (new, SwiftUI in an `NSPanel` like `RollEditController+Card.swift`).
- `ScoreRenderer*.swift`: meter at changes; the metronome mark at tempo changes; measure widths
  from `lengthUnits`.
- Status bar bar.beat label: already `grid.barBeatLabel`, follows.

## 5. Order of work

1. Core types and conversions, with tests; the app compiles with `bpm` unchanged in meaning.
2. Consumers: lines, snap, ruler labels, score measures, MusicXML, MIDI.
3. Toolbar TIME and per-segment tempo; ruler markers and card.
4. Beat tracker, meter estimator, map builder; Detect's landing and confirmation.
5. Changelog, CLAUDE.md / AGENTS.md departures sentence, close.

## 6. Changelog

"Set the time signature and add tempo changes on the ruler, or let Detect follow the take's
tempo through the whole recording; the grid, the score and the exports follow."
