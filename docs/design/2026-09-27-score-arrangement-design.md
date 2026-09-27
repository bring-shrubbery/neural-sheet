# Score arrangement: per-part display, tablature, pages and PDF — Design

The Score tab shows the transcription as one fixed rendering: a clef chosen by range, the
project's key, every part, one continuous scroll. A player wants the score *their* way: a
guitar part in tab in their tuning, a banjo in open G, a trumpet in its written key, a title
at the top, pages that print. This adds an **arrangement** to the project — per-part display
settings, a tablature library, sheet metadata, a page layout — and a **PDF export** of the pages.

It builds on the score design (`2026-09-27-score-view-design.md`), the MusicXML design
(`2026-09-27-musicxml-export-design.md`) and the key design (`2026-09-27-key-detection-design.md`).
Everything it does not mention is unchanged.

## 1. Goals and non-goals

Goals

- Every part can be shown in notation, in tablature, or both; with a chosen clef; at a written
  transposition, its key signature and accidentals respelled to match; or hidden.
- Tablature for every fretted instrument as a template with named tuning presets, or any custom
  tuning; the string each note is played on chosen automatically, changeable by hand, and drawn
  red when the note cannot be played there.
- A page layout beside the continuous one: A4 or Letter, a header block with the sheet's
  title, subtitle, composer and arranger, page numbers, a copyright footer.
- File → Export PDF… writes exactly the pages the view shows.
- The MusicXML export follows the same settings, so the file and the pages agree.
- Everything is saved in the project; a project saved by this build opens in the previous one.
- Every rule lives in `NeuralSheetCore` behind `swift test`; the AppKit renderer draws.

Non-goals

- Undo for the arrangement. It is display state, like the grid and the key.
- Beaming, chord symbols, lyrics, dynamics, articulations, concert-pitch switching, part
  extraction. Each is a later design; nothing here precludes them.
- Fingerings, bends, slides, hammer-ons or other tab ornaments. Fret numbers and rhythm.
- Landscape pages, custom margins, multiple movements.
- Editing notes in the score. The string choice is the one thing the score changes, and it is
  display state.

## 2. Decisions

| Question | Decision |
|---|---|
| Where the settings live | `ScoreArrangement`, a value in `project.json` (`arrangement`, optional; absent is the defaults) and in `ProjectContent`, so a change marks the project edited. Not in the undo stack. |
| Keyed by | Program, as the sidebar and the mixer are. A part that leaves the mix keeps its settings until the project is saved without it. |
| The written key | The project key transposed by the part's transposition; sharps or flats by the transposed signature. A part with no transposition shows the project key. |
| Transposition presets | Written = sounding + the preset: None (0); B♭ (+2: trumpet, clarinet, soprano sax); B♭ tenor (+14: tenor sax); E♭ alto (+9: alto sax, horn in E♭); E♭ baritone (+21: baritone sax); F (+7: horn); A (+3: clarinet in A); octave up (+12: guitar, bass, double bass); octave down (−12: piccolo, glockenspiel); and any number of semitones. |
| Clefs | Automatic (by range, as today), treble, bass, grand (two staves split at middle C), alto, tenor, treble 8vb, bass 8vb, percussion. |
| Tab default display | A fretted template puts the part in notation and tab, the staff above its tab. |
| String choice | Automatic: each chord's notes lowest first, each to the free string with the lowest fret at or above 0. A note no string can hold goes to the nearest string and is red. A manual choice, stored by note id, wins and is red when impossible. |
| Where the part controls are | A click on the part's name in the score opens a floating card at the pointer, the instrument card's shape, with the display, clef, transposition, template, tuning and hide controls. |
| Page sizes | A4 (210 × 297 mm) and US Letter (8.5 × 11 in), portrait, 15 mm margins, 18 mm at the top of page 1 for the header. |
| The staff space on a page | 7 pt, so a page holds what a printed part does; the continuous view keeps its 8 authored points. |
| Metadata | Title (default: the take's name, or "Untitled"), subtitle, composer, arranger, copyright (the footer); switches for measure numbers, part names and the tempo mark, all on by default. |
| PDF | One PDF context, one page per laid-out page, the same renderer as the view, at 72 pt per inch. Save panel titled "Export PDF" in the Music folder, `<name>_NNTranscription.pdf`. |
| Toolbar | A `ScoreToolbar` on the Score tab: Continuous / Pages, A4 / Letter, KEY, TEMPO, Parts, Sheet…, Export PDF. The Edit toolbar stays on the Edit tab. |
| Compatibility | `arrangement` is one optional key the previous version ignores; the Score tab still writes `edit` as its saved workspace. |

## 3. Core

### 3.1 `ScoreArrangement.swift`

```swift
public struct ScoreArrangement: Equatable, Codable, Sendable {
    public var parts: [Int: PartDisplay] = [:]           // by program; absent is PartDisplay()
    public var sheet = SheetMetadata()
    public var layout: ScoreLayoutMode = .continuous     // continuous, pages
    public var pageSize: PageSize = .a4                  // a4, letter
    public func display(for program: Int) -> PartDisplay
}

public struct PartDisplay: Equatable, Codable, Sendable {
    public enum Mode: String, Codable { case notation, tab, both }
    public var mode: Mode = .notation
    public var clef: ClefChoice = .automatic             // automatic, treble, bass, grand, alto, tenor, treble8vb, bass8vb, percussion
    public var transposition = 0                         // written = sounding + transposition, semitones
    public var tab: TabSetup? = nil                      // nil: no template chosen
    public var isHidden = false
    public var strings: [NoteID: Int] = [:]              // manual string choices, 0 = the lowest string
}

public struct TabSetup: Equatable, Codable, Sendable {
    public var template: TabTemplate.ID                  // "guitar", "bass", "banjo5", …
    public var tuning: [Int]                             // open pitches, bottom tab line first
    public var presetName: String?                       // the preset the tuning came from, or nil for custom
    public var frets: Int
}

public struct SheetMetadata: Equatable, Codable, Sendable {
    public var title: String? = nil                      // nil: the take's name
    public var subtitle = ""
    public var composer = ""
    public var arranger = ""
    public var copyright = ""
    public var showsMeasureNumbers = true
    public var showsPartNames = true
    public var showsTempo = true
}
```

Every field decodes with a default, so a file from a version that lacks one loads.

### 3.2 `TabTemplate.swift`

```swift
public struct TabTemplate: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String                              // "Banjo (5-string)"
    public let strings: Int
    public let frets: Int
    public let presets: [TuningPreset]                   // the first is the default
    public let defaultTransposition: Int                 // 12 for guitar and bass notation
    public static let all: [TabTemplate]
    public static func template(for program: Int) -> TabTemplate?   // guitars → guitar, basses → bass; else nil
}

public struct TuningPreset: Equatable, Sendable {
    public let name: String                              // "Open G (gDGBD)"
    public let pitches: [Int]                            // bottom tab line first, MIDI
    public var label: String                             // "D G B D" style note names
}
```

Templates and presets:

| Template | Strings | Frets | Presets |
|---|---|---|---|
| Guitar | 6 | 24 | Standard (EADGBE), Drop D, Half-step down, Whole-step down, DADGAD, Open G (DGDGBD), Open D (DADF♯AD), Open E |
| Guitar (7-string) | 7 | 24 | Standard (BEADGBE), Drop A |
| Bass | 4 | 24 | Standard (EADG), Drop D, Half-step down |
| Bass (5-string) | 5 | 24 | Standard (BEADG), Tenor (EADGC) |
| Bass (6-string) | 6 | 24 | Standard (BEADGC) |
| Banjo (5-string) | 5 | 22 | Open G (gDGBD), Double C (gCGCD), Sawmill (gDGCD), Open D (f♯DF♯AD), Drop C (gCGBD) |
| Banjo (tenor) | 4 | 19 | Standard (CGDA), Irish (GDAE), Chicago (DGBE) |
| Banjo (plectrum) | 4 | 22 | Standard (CGBD) |
| Mandolin | 4 | 20 | Standard (GDAE) |
| Ukulele | 4 | 15 | Standard (GCEA, high G), Low G, Baritone (DGBE) |
| Lap steel | 6 | 24 | C6 (CEGACE), Open E |

The banjo's fifth string is the highest-pitched but drawn as the lowest tab line, as banjo tab
does; templates carry `pitches` lowest-string-first in *tab line order*, so the fifth string
comes first with its high pitch, and the string chooser treats each string by its own pitch.

### 3.3 String assignment (`TabFingering.swift`)

```swift
public enum TabFingering {
    public struct Placement: Equatable, Sendable { var string: Int; var fret: Int; var isPlayable: Bool }
    public static func place(pitches: [Int], tuning: [Int], frets: Int, manual: [Int?]) -> [Placement]
}
```

For one chord: the notes ascending; a note with a manual string takes it, `fret = pitch −
tuning[string]`, playable when `0 ≤ fret ≤ frets` and the string is not already taken; every
other note takes, among the strings still free, the one whose fret is smallest but at or above
0; with none, the free string whose fret is nearest to the playable range, unplayable. A chord
with more notes than strings puts the surplus on the last string, unplayable.

Tests: an open-G banjo chord lands on open strings; an E2 on a guitar in standard is string 0
fret 0 and a D2 is string 0 fret −2 unplayable; a manual choice off the playable range is
kept and unplayable; a chord fills distinct strings; the surplus note is red.

### 3.4 Written pitch and clefs (`ScoreModel+Pitch.swift`)

- `Clef` gains `alto`, `tenor`, `treble8vb`, `bass8vb`; baselines: alto F3, tenor D3, the
  octave clefs the same as their parents (the octave is in the transposition, +12 for a
  guitar). `ClefChoice.resolve(for pitches:)` gives `automatic` its range rule.
- `ScoreDocument.build(notes:grid:key:arrangement:)`: per part, the written pitches are the
  sounding ones plus the transposition, the written key is the project key's tonic plus the
  transposition in the same mode (`MusicalKey.transposed(by:)`), spelling and accidentals follow
  the written key, and `ScoreNote.writtenPitch` is what the staff shows while `pitch` stays the
  sounding one for the tab and the cursor. Hidden parts are left out. A part in `tab` or `both`
  gets a `ScoreTabStaff` beside its staves: the same pieces, each note with its `Placement`.
- `ScorePart` gains `display: PartDisplay` and `tab: ScoreTabStaff?`; `ScoreNote` gains `id:
  NoteID?` (the document's, nil while a run streams) and `writtenPitch`.
- `MusicXMLWriter.unitNotes` carries the id through `UnitNote`.

Tests: a B♭ trumpet part in C major shows D major (two sharps) with the notes a tone up; a
guitar at +12 in the treble 8vb clef puts E2 on the bottom space's ledger as E3 would; alto
and tenor baselines; a hidden part is absent; the tab staff's placements.

### 3.5 Pages (`ScorePageLayout` in core, `ScoreLayout` in the UI)

The measure-packing and system geometry move from `UI/Score/ScoreLayout.swift` into the core as
`ScoreSystemLayout` (widths in points from a staff space, no AppKit), so the pagination can be
tested: `ScorePageLayout(document:, arrangement:, pageSize:, sp:)` gives `[Page]`, each with its
frame, header height (page 1) and the systems that fit under it, systems never split. The UI
layout becomes a thin wrapper choosing continuous or paged.

Tests: A4 and Letter frames in points; the first page's header pushes the first system down;
systems fill pages by height and none is split; a score of one system is one page.

### 3.6 Sheet defaults and file names

`SheetMetadata.resolvedTitle(takeName:)`; `PDFExport.fileName(sourceFileNameWithoutExtension:)`
→ `<name>_NNTranscription.pdf`.

## 4. Renderer (`UI/Score/ScoreRenderer.swift`, replacing the drawing in `ScoreView`)

`ScoreRenderer` draws a system, a tab staff, a header block and a footer into any `CGContext`
from the layout and the document, with a `Style` (ink, lines, red for unplayable) — the view
and the PDF export call it. The view keeps the cursor, the selection, hit-testing and the
clicks.

Tablature: `strings × 1.5 sp` tall, lines `Theme.textScale`, "TAB" in place of a clef, fret
numbers in the mono meta font on a small rounded background so they cover the line, red
(`Theme.warn`) when unplayable; stems and flags below the tab as the notation's, ties as arcs
under the numbers; a tab under its notation staff shares the piece x positions.

Header: the title centred in the sans at 3 sp, the subtitle below at 1.8 sp, the composer
right-aligned and the arranger under it at 1.6 sp; the footer's copyright centred at 1.2 sp with
the page number at the outer edge.

Selection: the renderer records each drawn tab note's frame and id into the layout's hit list;
`ScoreView` keeps `selectedTabNote: (program: Int, id: NoteID)?`, draws its frame with the
accent, and on ↑/↓ (via `KeyboardShortcuts` in the `.score` workspace) calls
`setString(program:id:string:)`; a right-click opens a card listing the strings with the fret
each would need, unplayable ones red.

## 5. Model

- `arrangement: ScoreArrangement` on `AppModel`, in `ProjectContent` and `ProjectState`
  (`arrangement`, optional), saved and restored with the rest; a new project has the defaults;
  `resetTranscription` keeps it (it is the project's, like the grid).
- `AppModel+Arrangement.swift`: `setPartMode`, `setPartClef`, `setPartTransposition`,
  `setPartTab(template:preset:)` (which also puts a part still in notation into notation and
  tab, and takes the template's default transposition when the part has none),
  `setPartTuning(string:pitch:)`, `setPartHidden`, `setString(program:id:string:)`
  (nil clears the manual choice), `setSheet(_:)`, `setScoreLayout(_:)`, `setPageSize(_:)`;
  `pruneStringChoices()` after every document change drops ids the document no longer has.
- `exportPDF()`: the pages from `ScorePageLayout` drawn by `ScoreRenderer` into a `CGPDFContext`;
  the failure dialog `"Error"` / `"Could not write the PDF file."`.
- `musicXMLData()` passes the arrangement; the writer emits per part `<clef>` from the choice,
  `<transpose><chromatic>`, `<staff-details><staff-lines>` and `<staff-tuning>` for a tab staff,
  `<technical><string>`/`<fret>` per tab note, and skips hidden parts; the `<work-title>`,
  `<creator type="composer">`, `<creator type="arranger">`, `<rights>` and a subtitle `<credit>`.

## 6. UI

- `ScoreToolbar`: Continuous / Pages as a two-segment `FlatButton` pair; A4 / Letter likewise,
  enabled in Pages; the KEY and TEMPO controls extracted from `EditToolbar` into a shared
  `GridControls` view; a `Parts` menu listing every instrument in the mix, ticked when shown;
  `Sheet…` opening the metadata card; `Export PDF`.
- `PartDisplayCard`: the part's chip and name; rows Display (Notation / Tab / Both), Clef
  (menu), Transposition (menu of presets plus a semitone field), Template (menu; "None"), Tuning
  (menu of the template's presets plus "Custom…", which shows one pitch field per string in tab
  line order), Frets, and a Hide switch. Opened by a click on the part name in the score.
- `SheetCard`: the six text fields and three switches.
- `ScoreContainerView` in Pages mode: a grey surround (`Theme.bgPanel`) with each page a
  `Theme.bgRoot` sheet at 72 pt per inch scaled by `\.uiScale`, a page gap of 24 pt; the
  cursor and following as today.
- File menu: `Export PDF…` after `Export MusicXML…`, enabled with them.

## 7. Departures from the inventory

- §6 gains a third exit, File → Export PDF…. NeuralNote wrote MIDI only.

## 8. Tests and verification

- Core tests as in §3; build warning-free; `swift test` green.
- The offscreen render harness for the tab staff, the header and a page, viewed as images.
- By hand: put a guitar part in Open G tab, pick a string for a note, watch it turn red off the
  fretboard; switch to Pages, add a title, export the PDF and open it in Preview; open the
  MusicXML in MuseScore and see the same clef, key and tab.

## 9. Order of work

1. **core**: `ScoreArrangement`, `TabTemplate`, `TabFingering`, the new clefs, transposition in
   the score model, the tab staff in the document; tests.
2. **app**: the arrangement on the model and in the project; the commands.
3. **ui**: the renderer split out of the view; the part card; the tab staff; string selection.
4. **core + ui**: `ScoreSystemLayout` into the core, `ScorePageLayout`, the paged container, the
   header and footer; the Score toolbar; the sheet card.
5. **app**: the PDF export and the menu item.
6. **core + app**: the MusicXML writer follows the arrangement.
7. **docs**: AGENTS.md departures, the changelog, the score design's note.

## 10. Decisions made during implementation

- The alto, tenor and octave clefs are drawn with Apple Symbols' C clef (U+1D121, at its SMuFL
  extents) and, for an octave clef, the parent glyph with a small "8" beneath it; flat key
  signatures on the alto clef take the treble pattern one step down.
- A part name wider than the left margin falls back to the part's abbreviation on the first
  system too, not only on the systems after it.
- The Score toolbar has a Parts menu listing every instrument in the mix, ticked when shown,
  because a hidden part loses its name in the score and with it the card that would show it
  again.
- Pagination keeps two staff spaces of slack above and below a system, so ink that overhangs
  the staff (ledger lines, a high clef, a low stem) stays out of the header and footer bands.
- The renderer takes a `Style`: the screen's dark palette in the Score tab, a print palette
  (white paper, black ink) in the PDF, which also draws no page edge.
- In the MusicXML export a part on an octave clef writes its pitches for that clef and drops
  the octave from `<transpose>`, since readers already shift a pitch for `clef-octave-change`.
