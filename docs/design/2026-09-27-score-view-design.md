# Score tab — Design

The MusicXML export writes a score nobody sees until another program opens it. AnthemScore,
ScoreCloud and Klangio show the notation beside the piano roll, and that view is where a
transcription's rhythm problems become obvious: a note a 16th late reads as a tie across the
beat. This adds a **Score** tab: the transcription as staff notation, exactly what the export
would write, following the playhead and seeking on click.

It builds on the MusicXML design (`2026-09-27-musicxml-export-design.md`), whose rhythm and
pitch rules it reuses, the key design (`2026-09-27-key-detection-design.md`) and the editor
design's tab shell (`2026-09-19-midi-editor-design.md` §3). Everything it does not mention is
unchanged.

## 1. Goals and non-goals

Goals

- A third tab, SCORE, unlocked with EDIT: every part on its staff or staves, systems wrapping to
  the window's width, clef, key and time signatures, bar lines and numbers, noteheads, stems,
  flags, dots, ties, rests, accidentals, ledger lines, the tempo marking.
- The score is the export: the same quantization, segmentation, staves and spelling, from the
  same core code, so what is seen is what MuseScore will open.
- The playhead runs through the score as a cursor; a click seeks; the view follows the cursor
  while the transport plays and Follow is on.
- The Edit toolbar stays above it, since the grid and the key are the score's parameters.
- The layout model lives in `NeuralSheetCore` behind `swift test`; the AppKit view turns it
  into pixels.

Non-goals

- Editing in the score. Notes are edited on the roll.
- Beams. Flags on every note; beaming needs a beat-grouping model the export does not have
  either.
- Engraving niceties: collision avoidance beyond seconds in a chord, slurs, dynamics, lyrics,
  page layout, printing, a PDF. A PDF export can follow once the drawing exists.
- Accidental memory within a bar. Every altered note carries its accidental; a natural appears
  where the key would alter the step. Unambiguous, if busier than an engraver would set it.

*Since the arrangement design (`2026-09-27-score-arrangement-design.md`): per-part display, tablature, pages and a PDF export.*

## 2. Decisions

| Question | Decision |
|---|---|
| Glyphs | Clefs and accidentals from Apple Symbols (𝄞 𝄢 ♯ ♭ ♮, which it has); noteheads, stems, flags, rests, the percussion clef, ledger lines, ties and bar lines as paths. |
| Staff space | 8 authored points, scaled by `\.uiScale`; staff lines 1 px. |
| Spacing | A piece is `2.5 + 1.2·log₂(units / 3)` spaces wide, plus 1.2 for an accidental; a measure is its pieces plus 1.5 spaces each side, at least 6 spaces; systems take as many measures as fit the width and stretch them to fill it, except the last. The first measure of a system carries the clef and the key signature; the first of all carries the time signature. |
| Stems | Up when the chord's mean step is below the middle line, down otherwise; 3.5 spaces from the outermost note; flags on the stem's end, one per level below a quarter. |
| Seconds | In a chord, a note one step above a placed note is set a notehead to the right. |
| Ties | A curve from a note's head to the next piece's head at that pitch, or to the measure's end when the tie leaves the system. |
| Ink | `Theme.textBright` on `Theme.bgRoot`; staff lines and bar lines `Theme.textScale`; the cursor `Theme.accent`; part names in the instrument's colour. |
| Cursor | The playhead's seconds through the grid to a measure and a position inside it, placed between the pieces' x positions by units. Seeking is the inverse, at the click's x within its measure. |
| Following | While playing with Follow on, the system under the cursor is scrolled into view when it changes. |
| Saved workspace | The project's `workspace` stays `transcribe` or `edit`; a project saved in the Score tab writes `edit`, so the file opens in the previous version. |
| Menu and key | View → Score, ⌘3. |

## 3. Core (`NeuralSheetCore/ScoreModel.swift`, `ScoreModel+Pitch.swift`)

```swift
public struct ScoreDocument: Equatable, Sendable {
    public var parts: [ScorePart]
    public var measureCount: Int
    public var firstBar: Int                     // bar index (from the downbeat) of measure 1
    public var fifths: Int
    public var bpm: Double
    public static func build(notes: [NoteEvent], grid: TempoGrid, key: MusicalKey?) -> ScoreDocument
    public func measureIndex(atSeconds: Double, grid: TempoGrid) -> (measure: Int, units: Double)?
    public func seconds(atMeasure: Int, units: Double, grid: TempoGrid) -> Double
}
public struct ScorePart: Equatable, Sendable { program, name, abbreviation, staves: [ScoreStaff] }
public struct ScoreStaff: Equatable, Sendable { clef: Clef, measures: [ScoreMeasure] }
public struct ScoreMeasure: Equatable, Sendable { pieces: [ScorePiece] }
public struct ScorePiece: Equatable, Sendable {
    startUnits: Int; units: Int; type: String; dots: Int
    notes: [ScoreNote]                            // empty for a rest
    isWholeMeasureRest: Bool
}
public struct ScoreNote: Equatable, Sendable {
    pitch: Int; step: Int                         // staff steps from the bottom line, 0 = bottom line
    accidental: Accidental?                       // sharp, flat, natural
    tiedFrom, tiedTo: Bool
    head: Head                                    // normal, x, diamond, triangle
}
public enum Clef: Sendable { treble, bass, percussion; func step(forSpelling:) }
```

`ScoreModel+Pitch.swift`: the diatonic step of a spelling, the clef baselines (treble E4, bass
G2, percussion as treble), the key signature's altered steps and their staff positions per clef
(`Clef.signaturePositions(fifths:) -> [Int]`), and which accidental a spelled note shows under a
key. `MusicalKey` gains `alteredSteps: [String: Int]` (G major → F: 1).

Tests: staff steps (middle C is −2 on the treble staff, 10 on the bass); a C major scale's
pieces are eight quarters over two measures with no accidentals; F♯ in C major shows a sharp and
F in G major a natural; the key signature positions for two sharps and three flats on both
clefs; a note across the bar is two pieces tied; a chord is one piece with its notes ascending;
a whole-measure rest; `measureIndex(atSeconds:)` and `seconds(atMeasure:)` invert each other;
the drums' heads.

## 4. App

- `Workspace.score`; `setWorkspace(.score)` allowed with `canEdit`; the tab strip's third
  button, View → Score ⌘3; `projectState` writes `edit` for `score`.
- `MainView`: the Edit toolbar for any tab but Transcribe; `ScoreTabView` in place of the
  timeline in the Score tab.
- `AppModel.scoreDocument`: rebuilt when the notes, the grid or the key change (a computed
  property over `notes`, `editor.grid`, `editor.key`; the view rebuilds its layout when the
  document it observes changes).

## 5. UI (`UI/Score/`)

- `ScoreTabView`: the `NSViewRepresentable` over a `ScoreContainerView` with a vertical
  `NSScrollView` and the document view.
- `ScoreLayout`: systems, measure frames, piece x positions and the prefix widths, from a
  `ScoreDocument`, a width and a scale.
- `ScoreView`: draws the layout — staves, bar lines, clefs, signatures, pieces, ties, part
  names, measure numbers, the tempo marking — and the cursor; a click seeks.
- `ScoreGlyphs`: the paths (noteheads, flags, rests, the percussion clef) and the text glyphs.
- Observation, as the timeline does it: one sync per burst of model writes; the cursor alone
  repaints on the playhead.

## 6. Departures from the inventory

- §3.1 of the editor design: a third tab. NeuralNote had no notation view.

## 7. Tests and verification

- Core tests as in §3; build warning-free; `swift test` green.
- By hand: a transcription reads as a score; the tabs switch without losing the roll's zoom;
  the cursor follows playback and a click seeks; resizing the window reflows the systems.

## 8. Order of work

1. **core**: `ScoreDocument` and its pitch helpers, `MusicalKey.alteredSteps`, tests.
2. **app**: the workspace case and its gates, the menu, the project mapping.
3. **ui**: the layout, the glyphs, the view, the tab.
4. **docs**: AGENTS.md departures, the changelog, the editor design's §3 note.
