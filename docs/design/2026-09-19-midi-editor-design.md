# MIDI editor and workspace tabs — Design

NeuralSheet v1 shows the transcription and lets you mix, play and export it. This adds the ability
to **edit** it — move, resize, add and delete notes, reassign them to other instruments, set their
velocity, snap and quantize them to a tempo grid — inside a new **Edit** tab, and makes the
transcription part of the saved session so edits survive a relaunch.

The window gains a DaVinci-Resolve-style tab strip: **Transcribe** (today's window) and **Edit**
(unlocked once a transcription exists). More tabs can follow.

This is the first feature past the parity checkpoint. Where it departs from the NeuralNote
inventory (`2026-09-17-neuralnote-feature-inventory.md`) it says so in §9; everything it does not
mention is unchanged.

## 1. Goals and non-goals

Goals

- Full note editing on the piano roll: select (click, marquee), move in time and pitch, resize
  either edge, insert, delete, duplicate, reassign instrument, set velocity, nudge from the
  keyboard, snap while dragging, quantize.
- A tab shell with a Transcribe tab and an Edit tab. The Edit tab gives the roll the height (the
  waveform shrinks to a strip) and the toolbar and sidebar to the editing tools.
- Unlimited undo/redo within a session, an Edit menu, and "Revert to transcription".
- The transcription (the model's output and the edited document) is saved in the session and
  restored with the audio.
- Every rule of the editor lives in `NeuralSheetCore` behind `swift test`; the AppKit layer only
  turns events into calls on it.

Non-goals (this spec)

- Auditioning a note on click or while dragging it. The render design has no main-actor path
  into the synth; it comes later as its own change.
- Time signatures other than 4/4, tempo changes, swing. The grid is one BPM, one offset.
- Velocity lanes, controller data, pitch bend, program changes inside a track.
- Multiple documents or a document file format. One session, as today.
- Persisting the undo history.

## 2. Decisions

| Topic | Decision |
|---|---|
| Editable model | A pure `NoteDocument` value in `NeuralSheetCore` with identified notes and an edit-batch undo stack (not `NSUndoManager` closures, not an edit overlay on the raw output) |
| Timeline | One shared `TimelineContainerView` with a `mode`; switching tabs keeps zoom, scroll, pitch range and the display link |
| Audio during edits | Every commit goes down the existing `scheduler.swap(notes:)` path; a drag in progress never touches the document |
| Velocity | The synth plays each note's `amplitude` as its velocity (was a constant 100) |
| Grid tempo | One project tempo: `exportTempo` is the grid's BPM; the grid also has a downbeat offset and a division |
| Waveform in Edit | 40 px strip instead of 126 px |
| Tools UI | The 44 px toolbar row holds the tools; the sidebar keeps the instrument strips and gains a selection inspector above Master |
| Persistence | Raw notes + document + editor settings in `session.json`, guarded by the audio's sample count |
| Revert | "Revert to Transcription…" rebuilds the document from the raw notes after a confirm dialog |

## 3. Tab shell

### 3.1 Tab strip

A 32 px row between the top bar and the sidebar/timeline block, full width, `Theme.bgTopBar`
background, 1 px `Theme.divStrong` bottom border. Tabs are left-aligned from x = 18 (the top bar's
left padding), 16 px apart, labelled **TRANSCRIBE** and **EDIT** in the sidebar-header font
(`Fonts.sectionHeader`, tracked), vertically centred.

| State | Look |
|---|---|
| Active | `Theme.textPrimary`, 2 px `Theme.accent` underline the width of the label, flush with the bottom border |
| Inactive | `Theme.textMuted`; hover `Theme.textPrimary` |
| Locked | inactive at the disabled alpha (0.38); tooltip "Transcribe the audio first" |

Shortcuts `⌘1` (Transcribe) and `⌘2` (Edit), also as **View → Transcribe / Edit** menu items. The
strip is a SwiftUI view (`UI/TabStrip.swift`), scaled through `\.uiScale` like everything else.

### 3.2 Workspace state

```swift
enum Workspace: String, Codable, Sendable { case transcribe, edit }
```

On `AppModel`:

- `var workspace: Workspace = .transcribe` (read-only from views).
- `var canEdit: Bool { state == .populated }`.
- `func setWorkspace(_:)`: `.edit` is refused unless `canEdit`.
- `transition(to:)` forces `workspace = .transcribe` whenever the new state is not `.populated`
  (clear, clear transcription, a new launch, recording).

### 3.3 What each tab shows

`TopBar` and `StatusBar` are the same on both tabs.

| Region | Transcribe | Edit |
|---|---|---|
| Sidebar | INSTRUMENTS header, strips, MASTER (unchanged) | INSTRUMENTS header, strips with the target rail (§6.2), SELECTION inspector (§6.3), MASTER |
| Toolbar row | file name, Drag MIDI out, bin (unchanged) | tool switcher, snap + division, tempo + downbeat, Quantize, Undo/Redo, Drag MIDI out (§6.1) |
| Timeline | waveform 126, ruler 22 (seconds), roll | waveform 40, ruler 22 (bars.beats), roll with grid, selection, previews |
| Overlays | Transcribe CTA, Load button, no-model notice, update notice | update notice only |

### 3.4 Shared timeline

`TimelineContainerView` gets

```swift
enum TimelineMode { case transcribe, edit }
var mode: TimelineMode
```

`TimelineMetrics.waveformHeight` and `pianoRollY` become functions of the mode
(`waveformHeight(.edit) == 40`). Setting `mode`:

1. re-lays the document (`layoutDocument`) and the overlays;
2. keeps `geometry.zoom`, the scroll origin and the pitch range as they are;
3. installs (`.edit`) or removes (`.transcribe`) the `RollEditController` on the roll and hands it
   the current editor state;
4. tells the waveform, the ruler and the roll their mode, and repaints all three.

The 40 px waveform draws the same peaks over a 14 px half-span about its centre, without the
`+1.0 / 0 / −1.0` gutter labels and without the Load button; it still seeks on click. The ruler
and the waveform strip are the only click-to-seek surfaces in Edit mode; the roll's click is
spent on selection.

### 3.5 Leaving a transcription with edits

`launchTranscription()`, `clear()` and `clearTranscription()` — from the button, the bin, the
shortcut or the menu — first ask when `document.isEdited`:

> **Discard your edits?** — The transcription has been edited. Transcribing again will throw the
> edits away. [Cancel] [Discard]

("Clearing will throw the edits away." for the two clears.)

A `Dialogs`-installed confirm, like the §11.7 message boxes but with two buttons. Playback is
allowed while editing; nothing pauses the transport.

## 4. The note document (`NeuralSheetCore`)

### 4.1 Types

```swift
public struct NoteID: Hashable, Codable, Sendable { public let raw: Int }

public struct EditableNote: Equatable, Codable, Sendable {
    public var id: NoteID
    public var note: NoteEvent
}

public struct NoteDocument: Equatable, Codable, Sendable {
    /// Sorted by `NoteEvent.<`, ties by id: what every reader iterates.
    public private(set) var notes: [EditableNote]
    /// `notes.map(\.note)`: what is drawn, played and exported.
    public var events: [NoteEvent] { get }
    public private(set) var undoStack: [EditBatch]     // newest last, capped at 100
    public private(set) var redoStack: [EditBatch]
    /// True once any batch has been committed, until `revert`. Survives undo-to-empty.
    public private(set) var isEdited: Bool
    private var nextID: Int

    public init(events: [NoteEvent])                    // ids 0..<count in sorted order
    public func note(_ id: NoteID) -> EditableNote?
    public mutating func commit(_ batch: EditBatch)
    public mutating func undo() -> EditBatch?           // the batch undone, for the menu title
    public mutating func redo() -> EditBatch?
    public var canUndo: Bool; public var canRedo: Bool
    public var undoTitle: String?; public var redoTitle: String?
}
```

`Codable` encodes `notes`, `isEdited` and `nextID`; the stacks are encoded as empty so a restored
document starts with no history (§8.1).

### 4.2 Edit batches

```swift
public struct EditBatch: Equatable, Codable, Sendable {
    public var title: String                      // "Move Notes", "Delete Note", "Quantize"...
    public var inserted: [EditableNote]
    public var deleted: [EditableNote]
    public var changed: [NoteChange]              // NoteChange { before, after }: Codable, unlike a tuple
    public var inverse: EditBatch                 // swaps inserted/deleted and before/after
    public var isEmpty: Bool
}
```

`commit` applies `deleted` (by id), `changed` (by id, replacing with `after`), then `inserted`;
re-sorts; pushes the batch; clears `redoStack`; sets `isEdited`. `undo` applies `inverse` and
moves the batch to `redoStack`; `redo` the reverse. An empty batch is ignored.

### 4.3 Commands

Pure builders on `NoteDocument`, each returning the batch to commit. Every builder runs the
result through the invariants (§4.4) so the batch it returns is exactly what `commit` applies.

| Builder | Notes |
|---|---|
| `insert(_ note: NoteEvent) -> EditBatch` | allocates the next id; title "Add Note" |
| `duplicate(_ ids: Set<NoteID>, deltaSeconds:, deltaSemitones:)` | inserts copies; "Duplicate Notes" |
| `delete(_ ids:)` | "Delete Note(s)" |
| `move(_ ids:, deltaSeconds: Double, deltaSemitones: Int)` | "Move Note(s)" |
| `resize(_ ids:, edge: NoteEdge, deltaSeconds: Double)` | `.start` moves the onset keeping the offset; `.end` the reverse; "Resize Note(s)" |
| `setStart(_ ids:, seconds:)` `setLength(_ ids:, seconds:)` `setPitch(_ ids:, pitch:)` | the inspector's absolute fields |
| `setProgram(_ ids:, program: Int)` | "Change Instrument"; a drum note given a melodic program becomes melodic and vice versa |
| `setVelocity(_ ids:, velocity: Int)` | 1…127 → `amplitude = velocity / 127`; "Set Velocity" |
| `quantize(_ ids:, grid: TempoGrid, lengths: Bool)` | starts to the nearest grid line, optionally lengths to the nearest multiple of the division (min one division); "Quantize" |

Velocity as seen by the UI is `Int((amplitude * 127).rounded())` clamped to 1…127
(`NoteEvent.velocity`, a new computed property).

### 4.4 Invariants

Applied to every `after` and `inserted` note by clamping, never by rejecting:

- `pitch` in 0…127.
- `startTime ≥ 0`; `endTime − startTime ≥ 0.010` s (`NoteDocument.minimumLength`). A move that
  would push the start below 0 stops at 0; a resize that would cross the other edge stops at the
  minimum length.
- `program` in 0…127 or `NoteEvent.drumProgram`.
- `amplitude` in 1/127…1.
- **Same-pitch overlap.** After the batch's own changes, if two notes of one instrument and pitch
  overlap (`earlier.endTime > later.startTime`), the earlier is trimmed to end at the later's
  start (never below the minimum length: if that would violate it, the earlier note is deleted
  instead). The trims and deletions join the batch, so they undo with it. Notes that merely
  touch do not overlap. This replaces `mergeOverlappingNotesWithSamePitch` for edited notes; the
  merge still runs once when the raw output becomes a document (§5.1).

### 4.5 Tempo grid

```swift
public enum GridDivision: String, CaseIterable, Codable, Sendable {
    case bar, half, quarter, eighth, sixteenth, thirtySecond, eighthTriplet, sixteenthTriplet
    public var label: String            // "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/8T", "1/16T"
    public var beats: Double            // in quarter notes: 4, 2, 1, 0.5, 0.25, 0.125, 1/3, 1/6
}

public struct TempoGrid: Equatable, Codable, Sendable {
    public var bpm: Double              // 20…300
    public var offsetSeconds: Double    // where bar 1 beat 1 falls; ≥ 0
    public var division: GridDivision

    public var secondsPerBeat: Double
    public var step: Double             // seconds per division
    public func snap(_ seconds: Double) -> Double         // nearest grid line, ≥ 0
    public func snapDown(_ seconds: Double) -> Double
    public func lines(from: Double, to: Double) -> [GridLine]   // GridLine { seconds, kind: .bar | .beat | .division }
    public func barBeat(at seconds: Double) -> (bar: Int, beat: Int)  // 1-based; bars before the offset count down from 0
}
```

4/4 only (what `MidiFileWriter` writes). Bar 1 starts at `offsetSeconds`; time before it is bar 0,
bar −1… so nothing is unreachable.

### 4.6 Gesture math

The controller's decisions are pure functions in `EditGestureMath.swift`, tested in Core:

- `hitZone(in noteRect: CGRect, at point: CGPoint, edgeWidth: CGFloat, minimumWidthForEdges: CGFloat) -> NoteHitZone?` (`.body`, `.startEdge`, `.endEdge`).
- `resolveMove(deltaSeconds:, deltaSemitones:, anchorStart:, snap: TempoGrid?, axisLock: AxisLock?) -> (deltaSeconds, deltaSemitones)`: snaps the *anchor note's* start to the grid and applies the same delta to every note, locks one axis to zero under ⇧.
- `resolveResize(edge:, deltaSeconds:, anchorEdgeTime:, snap:)`.
- `drawnNote(from anchor: Double, to current: Double, grid:, snapEnabled:, drawLength:) -> (start, end)`: the Draw tool's note; never shorter than one `drawLength`.
- `marqueeSelection(rect:, notes: [(NoteID, CGRect)]) -> Set<NoteID>`.

## 5. `AppModel` integration (`AppModel+Editing.swift`)

### 5.1 The document's place

- `transcription.rawNotes` remains the model's own output (the "raw transcription").
- `var document: NoteDocument?` — nil until a run completes. `handleFinished(.success)` sets
  `document = NoteDocument(events: mergeOverlappingNotesWithSamePitch(rawNotes))` and from then
  on `transcription.notes = document.events`. During `.processing` nothing changes: the streamed
  merge path is as it is today.
- `applyDocument()`: `transcription.notes = document.events`, then the existing chain —
  `ensureInstrument` for every program, `refreshMixerEntries`, `scheduler.swap(notes:)`,
  `refreshGains`. This is the *only* writer of `transcription.notes` once populated.

### 5.2 Commands (the views' contract)

```swift
func commit(_ batch: EditBatch)                       // document.commit + applyDocument
func undo() / redo()
var canUndo / canRedo: Bool, undoTitle / redoTitle: String?
func revertToTranscription()                          // confirm, then document = NoteDocument(events: merged raw)
func deleteSelection() / selectAll() / deselectAll() / quantizeSelectionOrAll()
func setSelection(_ ids: Set<NoteID>)                 // also called by the roll
func setTool(_:), setSnap(_:), setGridDivision(_:), setGridBpm(_:), setGridOffset(_:), setGridOffsetFromPlayhead()
func setTargetProgram(_:)
```

`exportTempo` is replaced by `editor.grid.bpm` (the Export dialog and the session read and write
it there). `midiData()` passes `startOffsetSeconds: editor.grid.offsetSeconds` so bar 1 in the
file is bar 1 on the grid.

### 5.3 Editor state

```swift
struct EditorState: Equatable {
    var tool: EditTool = .select              // .select, .draw, .erase
    var selection: Set<NoteID> = []
    var targetProgram: Int                    // the first strip's program until the user picks one
    var snapEnabled = true
    var grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)
}

/// The length of a newly drawn or inserted note: one grid division. No separate control in v1.
var drawLength: Double { editor.grid.step }
var editor = EditorState()
```

Shared on the model because the AppKit roll and the SwiftUI inspector both read it. The
selection is pruned of ids the document no longer has after every commit/undo/redo, and cleared
by `resetTranscription`. `targetProgram` is re-validated against `mixer.entries` whenever they
change (falls back to the first entry).

### 5.4 Menus and shortcuts

Edit menu (new `CommandGroup`): Undo `⌘Z` / Redo `⇧⌘Z` (titles "Undo Move Notes" etc. from the
batch; "Undo" / "Redo" disabled when empty), Delete `⌫`, Select All `⌘A`, Deselect All `⇧⌘A`,
Quantize `⌘U`, Revert to Transcription…. All disabled unless `workspace == .edit`. View menu gains Transcribe `⌘1` and Edit `⌘2`.

`KeyboardShortcuts` (the local monitor) adds, Edit tab only, main window, no text field focused:
`v` / `d` / `e` tools, `⌫` and forward-delete, arrow nudges (`←/→` one grid step, or 10 ms with
snap off; `↑/↓` one semitone; `⇧↑/↓` an octave), `Esc` (cancel drag, else deselect). `r` (record)
is refused in the Edit tab since recording is not possible from `.populated` anyway.

### 5.5 Velocity to the synth

`SynthEvent` gains `velocity: UInt8`. `NoteScheduler.collect` fills it from the note's
`amplitude` (`UInt8(clamping: Int((amplitude * 127).rounded()))`, minimum 1) for note-ons, 0 for
note-offs; `InstrumentSynthBank.schedule` sends `event.velocity` instead of the constant. One byte
in a pre-sized struct: no allocation, no lock, no property access on the render thread. Every note
the model produces still carries 100/127, so nothing sounds different until a velocity is edited.

## 6. UI

### 6.1 Edit toolbar (`Toolbar/EditToolbar.swift`)

Same 44 px row and metrics as `Toolbar` (buttons 28 tall at y 7, 12 px between groups, 14 px side
padding). Left to right:

1. **Tool switcher**: three `FlatButton`s in one 6 px-cornered group, 28 × 28, icons `Icons.arrow`,
   `Icons.pencil`, `Icons.eraser` (new, 13 px, 1.3 pt stroke like the rest). The active tool is
   the pressed look (`Theme.surfacePressed` fill, accent icon). Tooltips "Select (V)", "Draw (D)",
   "Erase (E)".
2. **Snap**: a toggle `FlatButton` with `Icons.magnet` (new), pressed look when on; tooltip
   "Snap to grid". Beside it the **division** button, label from `GridDivision.label` ("1/16"),
   opening a `MenuPanel` listing the eight divisions with the current one ticked.
3. **Tempo pill**, a numeric text field in the Export dialog's tempo-field style (20…300): label `TEMPO`, the BPM field; then label
   `BEAT 1 AT`, a seconds field (`0.000`, three decimals, ≥ 0), and a 28 × 28 `FlatButton` with
   `Icons.playheadTarget` (new) whose tooltip is "Set from playhead".
4. **Quantize**: a labelled `FlatButton`; tooltip "Quantize selection (⌘U)". Acts on the selection
   or, with nothing selected, every note. Quantizes starts only (lengths stay).
5. Flexible gap.
6. **Undo / Redo**: two icon `FlatButton`s (`Icons.undo`, `Icons.redo`, new), disabled at 0.38
   alpha when nothing to do; tooltips carry the batch title.
7. **Drag MIDI out**: the same view as the Transcribe toolbar's.

The file name and the bin are not on this row.

### 6.2 Sidebar strips in Edit mode

`InstrumentStrip` gets `isTarget: Bool` and `onChooseTarget: (() -> Void)?`. In Edit mode a click
on the name/chip area (not the fader, M or S) sets the target; the target strip draws a 2 px
`Theme.accent` rail down its left edge, inside the strip's bounds. In Transcribe mode neither is
passed and the strip is exactly as today.

### 6.3 Selection inspector (`Sidebar/SelectionInspector.swift`)

Above MASTER, `Theme.bgSidebar`, a 1 px `divSoft` line above it, `SidebarMetrics.paddingSide`
insets. Header **SELECTION** in the MASTER header style, with the count right-aligned in
`Fonts.mono` (`textMuted`): "3 notes", "1 note", "No selection". Then five rows, 22 px each,
label left (`Fonts.small`, `textMuted`), control right:

| Row | Control | Mixed selection | Commit |
|---|---|---|---|
| Instrument | popup button opening the 35-group + Drums `MenuPanel` (chip + name like the picker) | "—" | `setProgram` |
| Start | `mm:ss.ddd` text field | "—" | `setStart` (same start for every note) |
| Length | seconds field, three decimals | "—" | `setLength` |
| Pitch | note-name field (`C#4`, accepts a number too) | "—" | `setPitch` |
| Velocity | 1…127 field + a 60 px `PillSlider` | "—", slider at the mean | `setVelocity` |

Fields are disabled (0.38) with no selection. Each field commits one batch on Return or focus
loss; ↑/↓ in a field step by 1 (⇧ by 10). The inspector reads `model.editor.selection` and the
document, and is not shown in Transcribe mode.

### 6.4 Ruler in Edit mode

Labels bars and beats from `editor.grid`: at every bar line a `bar` label in `textPrimary`
(`Fonts.rulerLabel`), at every beat that clears the 56 px minimum gap a `bar.beat` label in
`textMuted`. Ticks at bars 1 px `divStrong` full height, at beats half height `divOctave`. When
even bars are closer than 56 px, every second/fourth bar is labelled (the existing
`RulerTicks.division` idea applied to bars). The ruler seeks on click in both modes (new: today
only the waveform and the roll seek).

### 6.5 Piano roll drawing in Edit mode (`PianoRollView+Editing.swift`)

- **Grid lines** under the lanes, over the lane fills: bar `divStrong`, beat `divOctave`,
  division `divSoft` at 50 % alpha, 1 px each (scaled). Division lines are skipped when the step
  is under 6 px; beat lines under 3 px. Drawn only in Edit mode.
- **Velocity**: note fill alpha `0.45 + 0.55 × (velocity − 1) / 126`, combined with the muted
  alpha as today.
- **Selection**: selected notes get a 1.5 px `Theme.textPrimary` inset outline (scaled) over the
  fill; the onset edge marker stays.
- **Preview**: with a `DragPreview` set, the notes it names are drawn at their previewed rects
  instead of their own (move/resize/duplicate), or not at all (erase), and a drawn-in note is
  drawn from the preview alone. The roll invalidates its visible rect per preview change.
- **Marquee**: `MarqueeView`, a layer-backed subview with a 1 px accent border and a 12 % accent
  fill, positioned by frame (never repainted).
- **Cursors**: `.arrow`; `.resizeLeftRight` over an edge; `.crosshair` for Draw; a 16 px eraser
  cursor drawn from `Icons.eraser` for Erase. `resetCursorRects` / tracking area on the roll.

## 7. The edit controller (`Timeline/Editing/RollEditController.swift`)

Owned by `TimelineContainerView` in Edit mode. `PianoRollView` holds it weakly as `interaction`
and forwards `mouseDown/Dragged/Up`, `mouseMoved`, `rightMouseDown` (no menu in v1: it selects
like a click) and cursor updates to it; without one the roll's click seeks as today.

### 7.1 Hit testing

`PianoRollView.hit(at point: CGPoint) -> (index: Int, id: NoteID, zone: NoteHitZone)?`: over the
second-buckets of the point's second, last-drawn note first (topmost wins), the zone from
`EditGestureMath.hitZone` with `edgeWidth = 6 × scale` and edges only on notes at least
`14 × scale` wide. Drum hits use their drawn (widened) rect.

The roll needs ids, so `setNotes` takes `[EditableNote]` in both modes. While a run streams in
there is no document yet; the container wraps `model.notes` with sequential placeholder ids,
which nothing hit-tests.

### 7.2 Drag sessions

```swift
enum DragKind { case move, duplicate, resize(NoteEdge), marquee, draw, erase }
struct DragSession { var kind: DragKind; var anchorPoint: CGPoint; var anchorID: NoteID?; var ids: Set<NoteID>; var axisLock: AxisLock?; var preview: DragPreview }
```

- **Mouse down** decides the kind from the tool, the hit and the modifiers (§7.3), updates the
  selection immediately for clicks, and records the anchor. A drag starts once the pointer has
  moved 3 px (scaled), so a click stays a click.
- **Mouse dragged** converts the pointer delta to seconds and semitones through the geometry,
  resolves it with `EditGestureMath` (snap when `snapEnabled != ⌘ held`, axis lock when ⇧ held),
  builds the `DragPreview` and pushes it to the roll. Marquee: updates `MarqueeView` and the
  live selection. Erase: hit-tests each moved-over note and adds it to the session's ids.
- **Auto-scroll**: while the pointer is outside the viewport horizontally the container scrolls
  time by up to 12 px per display-link tick in that direction (vertically: one key per 4 ticks);
  the link is resumed for the drag's duration.
- **Mouse up** builds one batch from the session (`move`, `duplicate`, `resize`, `insert`,
  `delete`) and `model.commit`s it; a marquee commits nothing. A drag with zero resolved delta
  commits nothing.
- **Escape** during a drag clears the preview and ends the session with nothing committed.

The document is never touched between mouse down and mouse up; the synth plays the pre-drag
notes throughout.

### 7.3 Tool behaviour

| Gesture | Select | Draw | Erase |
|---|---|---|---|
| click note | select it (⇧ toggles it in the selection) | same as Select | delete it |
| drag note body | move selection (an unselected note becomes the selection first); ⇧ locks the axis with the larger movement; ⌥ duplicates | same as Select | delete every note passed over |
| drag note edge | resize that edge of every selected note | same | — |
| click empty | deselect all | insert a `drawLength` note at the snapped time, pitch under the pointer, `targetProgram`, velocity 100 | — |
| drag empty | marquee: every note whose rect intersects it (⇧ adds to the selection) | insert; the end follows the pointer, snapped, never under one `drawLength` | — |
| double-click empty | insert, as Draw's click | — | — |

`v` / `d` / `e` switch tools; the toolbar shows which is active.

### 7.4 After a commit

The container's existing `sync()` sees `notes` change, calls `roll.setNotes` (full repaint — what
a decoded chunk costs today), `updateNoteRange(mayShrink: false)` so a note moved past the range
widens it, and reads `editor.selection` into the roll. The preview is cleared before the commit
so the roll never draws a note twice.

## 8. Persistence and export

### 8.1 Session

`SessionState` gains

```swift
public struct SessionTranscription: Codable, Equatable, Sendable {
    public var sourceSampleCount: Int          // of the 16 kHz mono buffer, the restore guard
    public var rawNotes: [NoteEvent]
    public var document: NoteDocument          // notes, isEdited, nextID; stacks empty
}
public var transcription: SessionTranscription? = nil
public var workspace: Workspace = .transcribe
public var gridOffsetSeconds: Double = 0
public var gridDivision: GridDivision = .sixteenth
public var snapEnabled = true
public var targetProgram: Int? = nil
```

(`exportTempo` stays and is the grid's BPM.) Missing keys fall back to defaults as today, so an
older `session.json` still opens. Saved through the existing throttled autosave; ~0.5 MB of JSON
for a 7 000-note song is fine there.

`restoreSession`: after `restoreAudio` succeeds and `source.mono16k.count == sourceSampleCount`,
install `rawNotes` and `document`, `applyDocument()`, `transition(to: .populated)`, then the
editor settings and, last, the workspace (so `.edit` is accepted). Any mismatch or a missing
audio file drops the transcription silently, as the audio is dropped today.

### 8.2 Export and drag

Unchanged path: `midiData()` reads `notes` and the grid's BPM; `startOffsetSeconds` is the grid
offset. The writer already emits `amplitude` as velocity, so edited velocities come out.

## 9. Departures from the inventory

Recorded in `AGENTS.md`'s list of deliberate departures:

1. A tab strip under the top bar; the Transcribe tab is the inventory's window.
2. In the Edit tab: the waveform is 40 px, the ruler shows bars and beats, the toolbar and the
   sidebar hold editing controls, and the roll's click selects rather than seeks.
3. The synth plays per-note velocity (the inventory fixes it at 100). Unedited notes are still 100.
4. Export tempo lives on the Edit toolbar as the project tempo (still in the Export dialog too).
5. The ruler seeks on click.
6. The session stores the transcription.

## 10. Testing

`swift test` in `Packages/NeuralSheetCore`, written before each implementation (TDD):

- `NoteDocumentTests`: init sorts and ids; each builder's batch; every invariant (clamping at 0,
  the minimum length, pitch and program ranges, velocity range); overlap trim and trim-to-delete,
  including that the trim undoes with the batch; undo/redo round-trips leave `notes` identical;
  redo cleared by a commit; the 100-batch cap; `isEdited` semantics; Codable round-trip drops the
  stacks.
- `TempoGridTests`: `step` per division including triplets; `snap` about the offset and at 0;
  `lines` kinds and counts over a span; `barBeat` before and after the offset.
- `EditGestureMathTests`: hit zones at the edges and on narrow notes; move resolution with snap,
  axis lock and a negative start; resize past the other edge; the drawn note's minimum; marquee
  containment vs intersection (intersection is the rule).
- `SessionStateTests`: round-trip with a transcription block; an old file without one.
- `MidiFileWriterTests`: a note with velocity 64 is written as 64 (exists as a formula; add the case).

App target: no XCTest bundle (as `AGENTS.md` decided). Every UI task ends with a warning-free Debug
build and, through the `run` skill, a screenshot of the gesture it added on a transcribed file.
The velocity byte change in the render path gets a specific review against the render-thread rules.

## 11. Implementation order

Each a separate commit (`core:`, `app:`, `ui:`, `audio:`), in this order so every step leaves a
working app:

1. **core**: `TempoGrid`; `NoteDocument` + `EditBatch` + builders + invariants; `EditGestureMath`;
   `NoteEvent.velocity`; `SessionState` block.
2. **audio**: the velocity byte through `SynthEvent`.
3. **app**: `Workspace`, `EditorState`, `document` on `AppModel`, `applyDocument`, the commands,
   the confirm dialogs, menus and shortcuts; grid BPM replaces `exportTempo`; session save/restore.
4. **ui**: `TabStrip` and `MainView` switching; `TimelineMode` in the container (waveform 40, ruler
   bars.beats, ruler seek, overlays hidden); the Edit toolbar with tempo/offset/snap/division and
   Undo/Redo working through the menu commands (no roll interaction yet).
5. **ui**: roll drawing in Edit mode (grid, velocity alpha, selection outline); ids into the roll;
   hit testing; `RollEditController` with Select tool: click, marquee, move, resize, duplicate,
   auto-scroll, keyboard nudges and delete.
6. **ui**: Draw and Erase tools; double-click insert; cursors.
7. **ui**: strips' target rail; the selection inspector; Quantize.
8. **docs**: `AGENTS.md` departures, README usage line, `CHANGELOG.md`.
