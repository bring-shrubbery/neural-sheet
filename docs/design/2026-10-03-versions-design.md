# Versions of the transcription — Design

Spec: [issue #23](https://github.com/bring-shrubbery/neural-sheet/issues/23).

The project keeps the model's output (`rawNotes`) and the edited document. This adds a list of
named snapshots of the notes beside them: saved by the user, saved automatically before any run
replaces a document, restored as an undoable edit, and drawn hollow behind the current notes for
comparison.

It builds on the projects design and the MIDI editor design. Everything this document does not
mention is unchanged.

## 1. Goals and non-goals

Goals

- Save, list, rename, delete, restore; automatic "Before <run>" snapshots; a ghost overlay and a
  difference selection; all in the project file, additive.

Non-goals

- Several takes, three-way compare, comparing anything but notes.

## 2. Decisions

| Question | Decision |
|---|---|
| Type | `NoteVersion { id: UUID, name: String, date: Date, notes: [NoteEvent] }`. `ProjectTranscription.versions: [NoteVersion]` (default `[]`, Codable additive). The "Transcription" entry is virtual: `rawNotes` presented first with a fixed id, not stored twice. |
| Saving | `AppModel.saveVersion(named:)` appends a version with `document.events`; `Save Version…` is an `NSAlert` with a text field (the Dialogs pattern), default name "Version N — 3 Oct 14:02" (medium date, short time). Marks the project edited (versions are part of `transcriptionSnapshot()`, so `isProjectEdited` sees them). |
| Automatic | In the three landings (full run, stems, region), when `document != nil` and the run will replace notes (full and stems: always; region: no — a region lands as an undoable batch, so it is covered by undo and needs no snapshot), `saveVersion(named: "Before Transcribe — <time>")` first. For a stems run the name is "Before Stems — <time>". |
| Restore | `document.replaceAll(with: notes)` → an `EditBatch` deleting every current note and inserting the version's with fresh ids, titled "Restore <name>"; `replaceDocumentAndCommit`. The Transcription entry restores `rawNotes` through the same batch (not through `installDocument`, so it is undoable; Revert to Transcription keeps its own non-undoable path as the inventory has it). |
| List UI | Edit → Versions ▸ Save Version… ⌥⌘S, ──, the versions (Transcription first; each item's title "name — N notes"), ──, Compare With ▸, Show Differences, ──, Manage Versions…. Rename and Delete live in *Manage Versions…*, a small sheet with a table (name editable in place, date, notes, Delete button), since SwiftUI menus have no hover actions. |
| Compare | `comparedVersion: NoteVersion?` on the model (view state). The container passes `ghostNotes: [NoteEvent]` to `PianoRollView`, drawn before the notes in `drawNotes`: the rect stroked 1 px in the instrument colour at alpha 0.5, no fill, both tabs. Band-windowed like the notes so a long version costs nothing off-screen. |
| Differences | `NoteMatcher.unmatched(current:, against:, startTolerance: 0.03, endTolerance: 0.06) -> (added: Set<NoteID>, missing: [NoteEvent])` in Core: greedy nearest-start matching per (program, pitch). Show Differences → `setSelection(added)`. The status bar's line gains " · N added, M missing vs <name>" while comparing (the status bar reads `statusLine`; add `comparison` to it). |
| Project file | `versions` inside `transcription.json`. A project with 20 versions of a 5 000-note song is ~10 MB of JSON; acceptable, and it compresses in the package if that ever matters. |

## 3. Core

- `NoteVersion.swift`; `ProjectTranscription.versions`; `NoteDocument.replaceAll(with:)`;
  `NoteMatcher.swift`.
- Tests: round trip with and without versions; `replaceAll` batch undoes to the old notes;
  matcher on identical sets (nothing), a moved note beyond tolerance (added + missing), a
  shifted note within tolerance (nothing).

## 4. App

- `AppModel+Versions.swift`: save, rename, delete, restore, compare, differences, the automatic
  snapshot hook called from the landings.
- `NeuralSheetApp.swift`: the submenu. `ManageVersionsSheet.swift` under `UI/`.
- `PianoRollView`: ghost drawing; `TimelineContainerView+Model.swift`: passes `ghostNotes`.
- `StatusBar.swift`: the comparison text.

## 5. Changelog

"Keep versions of the notes: Edit → Versions saves one by name (and one automatically before
every run), restores any, and ghosts one behind the roll to compare."
