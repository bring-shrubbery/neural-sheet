# MusicXML export — Design

NeuralSheet's only way out is a MIDI file. The name promises sheet music, and every notation
program — MuseScore, Dorico, Sibelius, Finale, Guitar Pro — opens MusicXML, which carries what
MIDI cannot: bars, note values, ties, rests, chords, staves and instrument names. This adds
**File → Export MusicXML…**: the transcription, quantized to the editor's grid, as a
`score-partwise` document with one part per instrument.

It builds on the editor design (`2026-09-19-midi-editor-design.md`, the grid) and mirrors the
MIDI exit (`MidiFileWriter`). Everything it does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A `.musicxml` file MuseScore opens without complaint: one part per instrument in the sidebar's
  order, 4/4 at the project tempo, bars from the grid's downbeat, notes quantized to the grid's
  division, chords, ties across bar lines and between split values, rests where nothing sounds,
  a treble or bass clef by range or two staves for a part that spans both, and a percussion
  staff for the drums.
- Every rule in `NeuralSheetCore` behind `swift test`, the documents checked by parsing them.
- The same exit shape as MIDI: the save panel in Music, `<name>_NNTranscription.musicxml`.

Non-goals

- Tuplets. A triplet grid division exports at the straight value of the same size (1/8T as
  1/8, 1/16T as 1/16). Proper tuplet groups come with a rhythm model this does not have.
- Voices beyond one per staff. Overlapping notes of different lengths become chords re-struck
  with ties at every onset, which is how a single voice can hold them and how MuseScore itself
  renders an unquantized import.
- Dynamics, articulations, lyrics, tempo changes, other meters, a key signature (the next
  design, key detection, fills `fifths`; this one writes 0 and spells with sharps).
- Compressed `.mxl`.

## 2. Decisions

| Question | Decision |
|---|---|
| Time base | 24 divisions per quarter: 32nds (3), 16ths (6), 8ths (12), quarters (24), and the dotted values between, all whole numbers. |
| Quantization | Each note's start and end to the nearest multiple of the grid division's units, straightened for triplets; a note shorter than one division is one division long. |
| Bars | 96 units from the grid's downbeat; the export starts at the first bar holding a note (bar 0 or earlier when notes precede the downbeat) and numbers its measures from 1. |
| Rhythm | Within a part's staff, every note start, note end and bar line is a boundary; between consecutive boundaries the sounding notes are constant and become one chord (or a rest). A chord longer than one printable value is split greedily (whole, dotted half, half, dotted quarter, quarter, dotted 8th, 8th, dotted 16th, 16th, 32nd) with ties between the pieces; a note sounding across a boundary is tied across it. |
| Staves | Two when at least a tenth of a part's notes are below middle C and a tenth at or above it (and it has eight notes); otherwise one, treble when the median pitch is at or above middle C, bass below. The drums get a percussion clef. |
| Drums | `<unpitched>` at the conventional five-line positions (kick F4, snare C5, hi-hats G5 with an x head, crashes A5 x, ride F5 x, toms between), anything else on C5. |
| Instrument identity | `<part-name>` from `Instruments.info(forProgram:)`, a `<midi-instrument>` with the channel `MidiFileWriter.channelMap` gives and the program plus one. |
| Tempo | A metronome direction and `<sound tempo>` in the first measure of the first part. |
| Dialog | None. The tempo and division are the Edit toolbar's. |
| File | `.musicxml`, `<name>_NNTranscription.musicxml` or `NNTranscription.musicxml`, save panel titled "Export MusicXML" in the Music folder. |
| Menu | File → Export MusicXML…, ⌥⇧⌘E, enabled with Export MIDI…. |

## 3. Core (`NeuralSheetCore`)

```swift
public enum MusicXMLWriter {
    public static let divisions = 24
    public static let barUnits = 96
    public static func data(notes: [NoteEvent], grid: TempoGrid, fifths: Int = 0, title: String? = nil) -> Data
    public static func exportFileName(sourceFileNameWithoutExtension: String?) -> String
}
```

`MusicXMLWriter+Rhythm.swift`: `UnitNote` (start, end, pitch in units), `quantum(for:)`,
`unitNotes(_:grid:quantum:)`, `Segment` and `segments(_:from:to:barLength:)`, `Duration` and
`printableDurations(_:)`.

`MusicXMLWriter+Pitch.swift`: `Spelling` and `spelling(midi:preferFlats:)`, `drumDisplay(note:)`,
`staffLayout(for pitches:)` (one clef, or two staves).

`MusicXMLWriter.swift`: the document, parts, measures, notes, rests, ties, chords, staves,
`<backup>` between staves, XML escaping.

Tests (`MusicXMLWriterTests`, parsing with `XMLDocument` and XPath): spelling in sharps and
flats; the greedy split (30 → quarter + 16th, 18 → dotted 8th); quantization to the 16th;
segmentation of two overlapping notes into three segments; a C major scale of quarters at 120
BPM gives two measures of four quarters and no rest; a note across the bar line gives two tied
notes; two notes at one onset give a `<chord/>`; a gap gives a whole-measure rest; drums give a
percussion clef and `<unpitched>`; a part above and below middle C gives two staves and a
`<backup>`; no notes give one measure with a rest; the file name rule.

## 4. App (`App/AppModel.swift`, `App/NeuralSheetApp.swift`)

- `musicXMLData() -> Data?` (nil unless `canExport`), `musicXMLExportFileName()`,
  `exportMusicXML()` with the save panel, beside the MIDI ones; the failure dialog `"Error"` /
  `"Could not write the MusicXML file."`.
- File menu: `Export MusicXML…` after `Export MIDI…`.

## 5. Departures from the inventory

- §6: a second exit, File → Export MusicXML…. NeuralNote wrote MIDI only.

## 6. Tests and verification

- `MusicXMLWriterTests` as in §3; build warning-free; `swift test` green.
- By hand: export a transcription and open it in MuseScore; the bars line up with the ruler's,
  the parts carry the sidebar's names, the drums sit on a percussion staff.

## 7. Order of work

1. **core**: the three writer files and the tests.
2. **app**: the model's export and the menu item.
3. **docs**: AGENTS.md departures, the changelog.
