# Section markers and lyrics — Design

Spec: [issue #18](https://github.com/bring-shrubbery/neural-sheet/issues/18).

Two kinds of text a transcription needs: names for its sections and words under its voice line.
Markers are project state in seconds, shown as flags on the ruler and rehearsal marks on the
score; lyrics are a field on the note, entered one syllable at a time or pasted as a verse, shown
in the note, under the staff, and in both exports.

It builds on the meter and tempo map design (the ruler card, bars) and the chord symbols design
(the pattern for project-state text on the timeline). Everything this document does not mention
is unchanged.

## 1. Goals and non-goals

Goals

- Markers: add, rename, drag, delete, jump, loop a section; in the score and both exports.
- Lyrics: syllable entry with word continuation and melisma, paste-and-distribute, roll and
  score display, both exports; undoable like any note edit.

Non-goals

- Verses, lyric styling, marker colours.

## 2. Decisions

| Question | Decision |
|---|---|
| Marker type | `Marker { id: UUID, seconds: Double, name: String }`; `ProjectState.markers: [Marker]` sorted by time, additive. |
| Marker commands | `AppModel+Markers.swift`: `addMarker(at:)`, `renameMarker(id:to:)`, `moveMarker(id:to:)`, `removeMarker(id:)`, `seekToMarker(before:/after:)`, `markRange(fromMarker:)`. Each marks the project edited; none touches the document. |
| Ruler | Flags in the ruler's accent, a 1 px stem at `x`, the name to the right clipped at the next flag; drawn after the grid labels and before the range band. Hit test on the flag's label rect: click selects nothing (the ruler still seeks on a plain click elsewhere), drag moves, double-click → `markRange(fromMarker:)`, right-click → the ruler card with the marker section. The Score tab's ruler strip (the playhead strip `ScoreContainerView` has) draws the flags too. |
| Keys | ⌥M adds; ⌥⌘← / ⌥⌘→ jump (menu shortcuts, Edit → Markers ▸ … and Go submenu items; `KeyboardShortcuts.swift` untouched). |
| Score | `ScoreDocument.rehearsalMarks: [(measure, text)]` from the markers through the grid (nearest bar). Drawn as boxed text at the system's left when the measure starts a system, else above the bar line, above the chord symbols' line if both are present. |
| MusicXML | `<direction placement="above"><direction-type><rehearsal>Verse</rehearsal></direction-type></direction>` as the first child of the measure in the first visible part. |
| MIDI | `FF 06 len text` in the conductor track at `quarterBeats(atSeconds:) × 960`. |
| Lyric type | `Lyric { text: String, syllabic: Syllabic (.single/.begin/.middle/.end), extends: Bool }`; `NoteEvent.lyric: Lyric?`, Codable `IfPresent`. |
| Lyric entry | `LyricCard` (the floating panel style) anchored to the note: a text field prefilled with the current text plus "-" or "_" marker as typed; Return/Tab commit and advance to the next note of the same program by start time (wrapping nowhere; the card closes after the last); Esc closes. Each commit is one `EditBatch` ("Lyric") through `document.setLyric(id:_:)`. Syllabic from the typed trailing marks: "-" → begin (or middle when the previous note of the program ends with begin/middle); no mark → single (or end when the previous was begin/middle); "_" → the same as no mark, with `extends = true`. |
| Paste Lyrics | `LyricSplitter.syllables(from text:) -> [Lyric]`: split on whitespace into words, each word on "-" into syllables with begin/middle/end (single when one piece); a trailing "_" on a syllable sets `extends`. `document.setLyrics(ids-in-order:, lyrics:)` one batch "Paste Lyrics". The dialog afterwards only when syllables were left over: "N syllables did not fit; select more notes." |
| Lyrics in commands | `move`, `setPitch`, `resize`, `setLength`, `setVelocity`, `setProgram`, quantize keep the lyric; `split` keeps it on the first half; `join` keeps the first's; `paste` keeps what the clipboard note had (lyrics travel with copied notes). |
| Roll | In `drawNote`, when `rect.width ≥ textWidth + 6` and `rect.height ≥ 9`, the text in the roll's small font, left-inset 3, vertically centred, in the note's ink colour (the colour the selection outline uses). Measured with a cached `NSAttributedString` size per text (an `NSCache`), never on the render thread (the roll is the main thread). |
| Score | A lyric line under each part's bottom staff: syllable centred on the note head's x; "-" centred between syllables of a word; an extender from the melisma syllable to the end of the last tied/held note. One line of height 2.5 staff spaces added to the system when the part has any lyric in it. |
| MusicXML | `<lyric number="1"><syllabic>begin</syllabic><text>Twin</text></lyric>`, `<extend type="start"/>` for melisma. |
| MIDI | `FF 05` at each syllable's onset on its instrument's track, text as typed (a trailing "-" appended for begin/middle so karaoke players join words). |

## 3. Core

- `Marker.swift`, `Lyric.swift` (+ `LyricSplitter`).
- `NoteDocument+Lyrics.swift`: `setLyric`, `setLyrics`.
- `ScoreModel`: `rehearsalMarks`, per-note `lyric` carried into `ScoreNote`; `ScoreSystemLayout`:
  the lyric line height.
- `MusicXMLWriter+Text.swift`: rehearsal and lyric elements. `MidiFileWriter`: the two meta
  events.

Tests: splitter on "Twin-kle twin-kle lit-tle star_" → 7 syllables with the right syllabic and
one extend; marker → measure mapping at and just before a bar line; MusicXML contains the
rehearsal and lyric elements in the right measure; MIDI meta bytes; document commands keep/drop
as specified; `ProjectState` round trip with markers.

## 4. App

- `AppModel+Markers.swift`, `AppModel+Lyrics.swift` (entry and paste), `RulerView+Markers.swift`,
  `RulerTempoCard` gains the marker section, `LyricCard.swift`, `drawNote`, the card and inspector
  field, `ScoreRenderer+Text.swift`, `NeuralSheetApp.swift` menu items (Edit → Markers ▸ Add Marker
  at Playhead ⌥M, Previous Marker ⌥⌘←, Next Marker ⌥⌘→; Edit → Lyric… ⌥L; Edit → Paste Lyrics…).

## 5. Changelog

"Name the sections and write the words: markers on the ruler (⌥M) become rehearsal marks in the
score and the exports, and Edit → Lyric… or Paste Lyrics… puts syllables under the voice line."
