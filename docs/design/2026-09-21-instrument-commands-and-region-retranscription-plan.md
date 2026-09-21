# Instrument Commands and Region Re-transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Whole-instrument reassign / split / delete from a right-click card on a sidebar strip, and a ruler-marked time range the model is re-run on with its own instrument choice, landing as one undoable batch.

**Architecture:** Four new `NoteDocument` commands in `NeuralSheetCore` (tested) produce ordinary `EditBatch`es. `AppModel` gains a transient `editor.range`, a `RegionJob` that drives the existing `TranscriptionEngine` on an audio slice and commits the result through `replaceDocumentAndCommit`, and three whole-instrument commands. The UI adds a ruler drag, an accent band over roll and waveform, a Re-transcribe button with a popup and progress group on the Edit toolbar, and a right-click card on the strip. Nothing changes in the project file.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in the app target), SwiftUI + AppKit, Swift Testing (`@Test`, `#expect`) in the core package, the muscriptor.cpp engine through the existing C bridge.

**Spec:** `docs/design/2026-09-21-instrument-commands-and-region-retranscription-design.md`. Read it first; section numbers below (§) refer to it.

## Global Constraints

- Build must be warning-free in our sources: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20`.
- Core tests must pass: `cd app/Packages/NeuralSheetCore && swift test`.
- Never edit `project.pbxproj`; new source files are picked up automatically.
- Views use the `AppModel` public contract only: no `transition(to:)`, no `transcription`, `engine`, `synthBank`, `recorder`, `transcriber` from a view. Every note change goes through `AppModel.commit` / `replaceDocumentAndCommit`.
- Files stay under roughly 400 lines; new work goes in new `+Extension.swift` files where a file is near that.
- Commit after every task, one commit per task, message `area: what` in lowercase (`core:`, `app:`, `ui:`, `docs:`), body says why when not obvious. End every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Titles of batches, verbatim: "Change Instrument", "Split Instrument", "Delete Instrument", "Re-transcribe".
- Context margin `2.0` s each side; minimum range `0.1` s; model sample rate `16_000`.
- User-facing strings use the wording in the spec exactly.
- `AGENTS.md`'s "Deliberate departures so far" list and `CHANGELOG.md` Unreleased / Added are updated in the last task.

---

## File map

Created:

- `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+InstrumentCommands.swift` — reassign, split, deleteInstrument
- `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+Region.swift` — replace(range:with:)
- `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/RegionSlice.swift` — slice bounds math
- `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentInstrumentCommandTests.swift`
- `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentRegionTests.swift`
- `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/RegionSliceTests.swift`
- `app/NeuralSheet/App/AppModel+RegionTranscription.swift` — RegionJob, retranscribe, cancel, completion
- `app/NeuralSheet/App/AppModel+Instruments.swift` — the three whole-instrument commands
- `app/NeuralSheet/UI/Timeline/RangeBandView.swift` — the band over roll and waveform
- `app/NeuralSheet/UI/Toolbar/RetranscribeButton.swift` — button, popup, RegionProgress
- `app/NeuralSheet/UI/Controls/RightClickCatcher.swift`
- `app/NeuralSheet/UI/Sidebar/InstrumentPicker.swift` — the shared "in the mix first" instrument menu
- `app/NeuralSheet/UI/Sidebar/InstrumentCard.swift`

Modified (what for):

- `NoteDocument+Commands.swift` — `changing` and `finished` become internal
- `AppModel.swift` — `regionJob` stored property, `transition(to:)` clears the range, `resetTranscription` clears range and job, guards on `clear`, `clearTranscription`, `loadAudio`
- `AppModel+Editing.swift` — `EditorState.range`, `retranscribeGroups`; `canEdit`; range commands; Escape order; `commit`/`undo`/`redo`/`revertToTranscription` guards
- `AppModel+Transcription.swift` — `failureReason` becomes internal
- `RulerView.swift` — drag marks a range
- `PianoRollView.swift`, `PianoRollView+Editing.swift`, `WaveformView.swift` — the band
- `TimelineDrawing.swift` — palette entries
- `TimelineContainerView.swift`, `TimelineContainerView+Model.swift` — wiring, snapshot, layout
- `RollEditController.swift` — `canEdit` guards
- `EditToolbar.swift` — the button slot
- `TranscriptionProgress.swift` — split into `ProgressGroup` + wrapper
- `PopupMenuPresenter.swift` — title/footer on `show`
- `SelectionFields.swift` — uses `InstrumentPicker`; `PitchField` internal
- `InstrumentStrip.swift`, `Sidebar.swift` — right-click wiring and the card presenter
- `AGENTS.md`, `CHANGELOG.md`, the spec (title format)

---

### Task 1: Whole-instrument document commands (core)

**Files:**
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+Commands.swift:164,181` (drop `private` on `changing` and `finished`)
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+InstrumentCommands.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentInstrumentCommandTests.swift`

**Interfaces:**
- Consumes: `NoteDocument.changing(_:title:_:)`, `NoteDocument.finished(_:)` (made internal here), `EditBatch`, `EditableNote`.
- Produces:
  - `func reassign(program: Int, to destination: Int) -> EditBatch`
  - `func split(program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) -> EditBatch`
  - `func deleteInstrument(program: Int) -> EditBatch`
  - `func notes(ofProgram program: Int) -> [EditableNote]` (internal)

- [ ] **Step 1: Write the failing tests**

```swift
// NoteDocumentInstrumentCommandTests.swift
import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program)
}

@Test func reassignMovesEveryNoteOfTheProgramAndMergesOverlaps() {
    var document = NoteDocument(events: [
        note(0, 2, pitch: 60, program: 0),   // piano C4, runs into the guitar's C4
        note(0, 1, pitch: 64, program: 0),
        note(1, 3, pitch: 60, program: 24),  // guitar C4
        note(5, 6, pitch: 40, program: 33),  // bass, untouched
    ])
    let original = document.events

    let batch = document.reassign(program: 0, to: 24)
    #expect(batch.title == "Change Instrument")
    document.commit(batch)

    #expect(document.events.allSatisfy { $0.program != 0 })
    #expect(document.events.filter { $0.program == 33 } == [note(5, 6, pitch: 40, program: 33)])
    // The piano's C4 overlapped the guitar's and is trimmed to where the guitar's starts.
    #expect(document.events.filter { $0.program == 24 && $0.pitch == 60 }
        == [note(0, 1, pitch: 60, program: 24), note(1, 3, pitch: 60, program: 24)])

    #expect(document.reassign(program: 24, to: 24).isEmpty)
    #expect(document.reassign(program: 99, to: 24).isEmpty)

    _ = document.undo()
    #expect(document.events == original)
}

@Test func reassignToDrumsAndBackFollowsSetProgram() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60, program: 0)])
    document.commit(document.reassign(program: 0, to: NoteEvent.drumProgram))
    #expect(document.events == [note(0, 1, pitch: 60, program: NoteEvent.drumProgram)])
    #expect(document.events[0].isDrum)
}

@Test func splitSendsTheNotesOnOneSideOfThePitch() {
    var document = NoteDocument(events: [
        note(0, 1, pitch: 36, program: 0),
        note(0, 1, pitch: 47, program: 0),
        note(0, 1, pitch: 48, program: 0),
        note(0, 1, pitch: 72, program: 0),
        note(0, 1, pitch: 40, program: 33), // another instrument, never moved
    ])
    let original = document.events

    let above = document.split(program: 0, atPitch: 48, sendingAbove: true, to: 33)
    #expect(above.title == "Split Instrument")
    #expect(Set(above.changed.map(\.after.note.pitch)) == [48, 72])
    #expect(above.changed.allSatisfy { $0.after.note.program == 33 })

    let below = document.split(program: 0, atPitch: 48, sendingAbove: false, to: 33)
    #expect(Set(below.changed.map(\.after.note.pitch)) == [36, 47])

    #expect(document.split(program: 0, atPitch: 48, sendingAbove: true, to: 0).isEmpty)
    #expect(document.split(program: 0, atPitch: 100, sendingAbove: true, to: 33).isEmpty)

    document.commit(below)
    #expect(document.events.filter { $0.program == 33 }.map(\.pitch) == [36, 40, 47])
    _ = document.undo()
    #expect(document.events == original)
}

@Test func deleteInstrumentRemovesOnlyThatProgram() {
    var document = NoteDocument(events: [
        note(0, 1, pitch: 60, program: 0),
        note(0, 1, pitch: 36, program: NoteEvent.drumProgram),
        note(2, 3, pitch: 62, program: 0),
    ])
    let original = document.events

    let batch = document.deleteInstrument(program: 0)
    #expect(batch.title == "Delete Instrument")
    #expect(batch.deleted.count == 2)
    document.commit(batch)
    #expect(document.events == [note(0, 1, pitch: 36, program: NoteEvent.drumProgram)])
    #expect(document.deleteInstrument(program: 5).isEmpty)

    _ = document.undo()
    #expect(document.events == original)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter NoteDocumentInstrumentCommandTests 2>&1 | tail -20`
Expected: compile errors, `value of type 'NoteDocument' has no member 'reassign'`.

- [ ] **Step 3: Make the helpers internal**

In `NoteDocument+Commands.swift` change

```swift
    private func changing(_ sources: [EditableNote], title: String, _ transform: (NoteEvent) -> NoteEvent) -> EditBatch {
```
to
```swift
    func changing(_ sources: [EditableNote], title: String, _ transform: (NoteEvent) -> NoteEvent) -> EditBatch {
```
and
```swift
    private func finished(_ batch: EditBatch) -> EditBatch {
```
to
```swift
    func finished(_ batch: EditBatch) -> EditBatch {
```

Update the doc comment above `changing` to say: "Internal rather than private: the whole-instrument commands (`+InstrumentCommands`) and the region replacement (`+Region`) build their batches on the same helpers."

- [ ] **Step 4: Write the commands**

```swift
// NoteDocument+InstrumentCommands.swift
import Foundation

/// Whole-instrument commands (instrument commands design §3.1): every note of one program at
/// once. Each is one batch through the same invariants as the per-note commands, so a merge
/// that lands two notes of one instrument on one pitch at once trims the earlier the way a
/// per-note reassign does.
extension NoteDocument {
    /// Every note of `program` given `destination`. With `destination` already in the mix this is
    /// the merge. Empty for no such notes, or a destination that is the program itself.
    public func reassign(program: Int, to destination: Int) -> EditBatch {
        guard destination != program else { return EditBatch(title: "Change Instrument") }

        return changing(notes(ofProgram: program), title: "Change Instrument") { note in
            var note = note
            note.program = destination

            return note
        }
    }

    /// The notes of `program` at or above `pitch` -- or, with `sendingAbove` false, below it --
    /// given `destination`. The boundary pitch itself goes above.
    public func split(program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) -> EditBatch {
        guard destination != program else { return EditBatch(title: "Split Instrument") }

        let moving = notes(ofProgram: program).filter { sendingAbove ? $0.note.pitch >= pitch : $0.note.pitch < pitch }

        return changing(moving, title: "Split Instrument") { note in
            var note = note
            note.program = destination

            return note
        }
    }

    /// Every note of `program` deleted.
    public func deleteInstrument(program: Int) -> EditBatch {
        EditBatch(title: "Delete Instrument", deleted: notes(ofProgram: program))
    }

    /// The notes of one instrument, in document order.
    func notes(ofProgram program: Int) -> [EditableNote] {
        notes.filter { $0.note.program == program }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -5`
Expected: all tests pass, including the four new ones.

- [ ] **Step 6: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: whole-instrument reassign, split and delete commands

One batch per command through the existing invariants, so a merge trims
the same-pitch overlaps it creates like a per-note reassign.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Range replacement command (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+Region.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentRegionTests.swift`

**Interfaces:**
- Consumes: `NoteDocument.finished(_:)`, `allocateID()`.
- Produces: `mutating func replace(range: Range<Double>, with notes: [NoteEvent]) -> EditBatch`, title "Re-transcribe".

- [ ] **Step 1: Write the failing tests**

```swift
// NoteDocumentRegionTests.swift
import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program)
}

@Test func replaceOwnsNotesByWhereTheyStart() {
    var document = NoteDocument(events: [
        note(0, 3, pitch: 60),     // crosses the start: kept whole
        note(2, 3, pitch: 64),     // starts inside: deleted
        note(4.9, 7, pitch: 67),   // starts inside, runs past the end: deleted
        note(5, 6, pitch: 69),     // starts at the upper bound: kept
        note(8, 9, pitch: 71),     // after: kept
    ])
    let original = document.events
    let existingIDs = Set(document.notes.map(\.id))

    let batch = document.replace(range: 1 ..< 5, with: [
        note(0.5, 1.5, pitch: 62), // starts in the margin: dropped
        note(1, 2, pitch: 62),     // kept
        note(4, 6.5, pitch: 65),   // runs past the end: keeps its length
        note(5, 6, pitch: 72),     // starts at the upper bound: dropped
    ])

    #expect(batch.title == "Re-transcribe")
    #expect(batch.deleted.map(\.note) == [note(2, 3, pitch: 64), note(4.9, 7, pitch: 67)])
    #expect(batch.inserted.map(\.note) == [note(1, 2, pitch: 62), note(4, 6.5, pitch: 65)])
    #expect(Set(batch.inserted.map(\.id)).isDisjoint(with: existingIDs))

    document.commit(batch)
    #expect(document.events == [
        note(0, 3, pitch: 60), note(1, 2, pitch: 62), note(4, 6.5, pitch: 65), note(5, 6, pitch: 69), note(8, 9, pitch: 71),
    ])

    _ = document.undo()
    #expect(document.events == original)
}

@Test func replaceTrimsSeamOverlapsOnOneInstrumentAndPitch() {
    var document = NoteDocument(events: [
        note(0, 3, pitch: 60),              // sounding into the range; the new C4 at 2 cuts it
        note(6, 8, pitch: 60),              // after the range; the new C4 running to 7 is cut by it
        note(6, 8, pitch: 60, program: 24), // another instrument: not touched
    ])

    let batch = document.replace(range: 1 ..< 5, with: [note(2, 2.5, pitch: 60), note(4, 7, pitch: 60)])
    document.commit(batch)

    #expect(document.events == [
        note(0, 2, pitch: 60), note(2, 2.5, pitch: 60), note(4, 6, pitch: 60),
        note(6, 8, pitch: 60), note(6, 8, pitch: 60, program: 24),
    ])
}

@Test func replaceWithNothingDeletesTheRangeAndIsEmptyWhenNothingChanges() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(2, 3, pitch: 62)])

    let cleared = document.replace(range: 1.5 ..< 4, with: [])
    #expect(cleared.deleted.map(\.note) == [note(2, 3, pitch: 62)])
    #expect(cleared.inserted.isEmpty)

    #expect(document.replace(range: 5 ..< 6, with: [note(7, 8, pitch: 60)]).isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter NoteDocumentRegionTests 2>&1 | tail -20`
Expected: compile error, no member `replace`.

- [ ] **Step 3: Write the command**

```swift
// NoteDocument+Region.swift
import Foundation

/// The region re-run's landing (design §3.1, §5.1): the notes starting in a range swapped for
/// the run's notes starting in it.
extension NoteDocument {
    /// A note is owned by where it starts, so one crossing the range's start is kept whole and
    /// one crossing its end keeps its length. Notes in `notes` that start outside the range came
    /// from the run's context margin and are dropped. Seam overlaps on one instrument and pitch
    /// are trimmed by `finished`. Mutating, since the inserted notes need ids.
    public mutating func replace(range: Range<Double>, with notes: [NoteEvent]) -> EditBatch {
        let doomed = self.notes.filter { range.contains($0.note.startTime) }
        var inserted: [EditableNote] = []

        for note in notes.sorted() where range.contains(note.startTime) {
            inserted.append(EditableNote(id: allocateID(), note: note))
        }

        return finished(EditBatch(title: "Re-transcribe", inserted: inserted, deleted: doomed))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: replace a time range's notes with a run's

Owned by onset: a note crossing the range start is kept whole, one
crossing the end keeps its length, and the seams are trimmed by the
document's overlap rule.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Region slice math (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/RegionSlice.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/RegionSliceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RegionSlice: Equatable, Sendable {
      public static let contextSeconds = 2.0
      public static let minimumRangeSeconds = 0.1
      public static let sampleRate = 16_000
      public var start: Double
      public var end: Double
      public init?(range: Range<Double>, duration: Double, context: Double = RegionSlice.contextSeconds)
      public func sampleRange(sampleCount: Int) -> Range<Int>
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// RegionSliceTests.swift
import Testing

@testable import NeuralSheetCore

@Test func regionSliceWidensByTheContextAndClampsToTheTake() {
    let inside = RegionSlice(range: 10 ..< 15, duration: 60)
    #expect(inside?.start == 8)
    #expect(inside?.end == 17)
    #expect(inside?.sampleRange(sampleCount: 60 * 16_000) == 128_000 ..< 272_000)

    let atStart = RegionSlice(range: 0.5 ..< 3, duration: 60)
    #expect(atStart?.start == 0)
    #expect(atStart?.end == 5)

    let atEnd = RegionSlice(range: 58 ..< 60, duration: 60)
    #expect(atEnd?.start == 56)
    #expect(atEnd?.end == 60)
    // A take whose sample count falls short of its duration is not overrun.
    #expect(atEnd?.sampleRange(sampleCount: 959_000) == 896_000 ..< 959_000)
}

@Test func regionSliceRefusesASliverAndARangeOffTheTake() {
    #expect(RegionSlice(range: 10 ..< 10.05, duration: 60) == nil)
    #expect(RegionSlice(range: 61 ..< 62, duration: 60) == nil)
    #expect(RegionSlice(range: 1 ..< 2, duration: 0) == nil)
    #expect(RegionSlice(range: 59.95 ..< 61, duration: 60) != nil, "a range running off the end is clamped, not refused")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter RegionSliceTests 2>&1 | tail -20`
Expected: compile error, `cannot find 'RegionSlice'`.

- [ ] **Step 3: Write the type**

```swift
// RegionSlice.swift

/// The stretch of audio a region re-run is given (design §5.3, §5.4): the marked range widened
/// by the context margin on each side and clamped to the take. The lead-in is what lets a note
/// already sounding at the range start be decoded with its onset before the range, and dropped;
/// the tail lets the model place the offset of a note that runs past the end.
public struct RegionSlice: Equatable, Sendable {
    /// Seconds of audio the model sees before the range and after it.
    public static let contextSeconds = 2.0
    /// The shortest range worth a run.
    public static let minimumRangeSeconds = 0.1
    /// The model's only sample rate.
    public static let sampleRate = 16_000

    /// Seconds from the start of the take.
    public var start: Double
    public var end: Double

    /// Nil for a range under the minimum, a take with no length, or a range starting past the
    /// take's end. A range running off the end is clamped.
    public init?(range: Range<Double>, duration: Double, context: Double = RegionSlice.contextSeconds) {
        guard range.upperBound - range.lowerBound >= RegionSlice.minimumRangeSeconds,
              duration > 0, range.lowerBound < duration
        else { return nil }

        start = max(0, range.lowerBound - context)
        end = min(duration, range.upperBound + context)
    }

    /// The slice as indices into a 16 kHz signal of `sampleCount` samples, never past its end.
    public func sampleRange(sampleCount: Int) -> Range<Int> {
        let rate = Double(RegionSlice.sampleRate)
        let lower = min(max(Int((start * rate).rounded()), 0), sampleCount)
        let upper = min(max(Int((end * rate).rounded()), lower), sampleCount)

        return lower ..< upper
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: the audio slice a region re-run is given

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The range on the model (app)

**Files:**
- Modify: `app/NeuralSheet/App/AppModel+Editing.swift` (`EditorState`, `escapePressed`, new range commands)
- Modify: `app/NeuralSheet/App/AppModel.swift` (`transition(to:)` at ~line 180, `resetTranscription` at ~line 685)

**Interfaces:**
- Produces: `EditorState.range: Range<Double>?`, `EditorState.retranscribeGroups: [InstrumentGroup]?`, `AppModel.setRange(_:)`, `AppModel.clearRange()`. Escape order: drag, selection, range.
- Consumes: `RegionSlice.minimumRangeSeconds`.

- [ ] **Step 1: Add the state**

In `EditorState` (AppModel+Editing.swift), after `var grid = TempoGrid()`:

```swift
    /// The stretch marked on the ruler for Re-transcribe (region design §4.2), half-open seconds.
    /// Transient: not in the project file.
    var range: Range<Double>?
    /// The instruments the last Re-transcribe popup settled on this session; nil until it has
    /// been opened, when the popup presets the instruments in the mix. Empty is Automatic.
    var retranscribeGroups: [InstrumentGroup]?
```

- [ ] **Step 2: Add the commands and the Escape order**

Replace `escapePressed` in AppModel+Editing.swift with:

```swift
    /// Escape: a drag in progress is cancelled; else the selection goes; else the range (region
    /// design §6.3). Two Escapes from a selection inside a range clear both.
    func escapePressed() {
        if dragCanceller?() == true { return }

        if !editor.selection.isEmpty {
            deselectAll()
            return
        }

        clearRange()
    }

    // MARK: - Range

    /// The ruler's drag: clamped to the take; a range under the minimum is no range, so a drag
    /// that ends as a sliver clears rather than marks.
    func setRange(_ range: Range<Double>) {
        let lower = max(0, range.lowerBound)
        let upper = min(duration, range.upperBound)

        guard upper - lower >= RegionSlice.minimumRangeSeconds else {
            clearRange()
            return
        }

        let clamped = lower ..< upper

        if editor.range != clamped {
            editor.range = clamped
        }
    }

    func clearRange() {
        if editor.range != nil {
            editor.range = nil
        }
    }
```

- [ ] **Step 3: Clear it with the transcription and on leaving populated**

In `AppModel.swift`, `transition(to:)`, after the `workspace = .transcribe` block:

```swift
        // The range marks a stretch of a finished transcription; there is none to mark otherwise.
        if newState != .populated, editor.range != nil {
            editor.range = nil
        }
```

In `resetTranscription()`, after `editor.selection = []`:

```swift
        editor.range = nil
```

- [ ] **Step 4: Build**

Run: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`, no warnings in our files.

- [ ] **Step 5: Commit**

```bash
git add app/NeuralSheet/App
git commit -m "app: a transient time range on the editor state

Set by the ruler, cleared by Escape after the selection, by every clear
and on leaving the populated state. Not in the project file.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Ruler drag and the range band (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Timeline/RulerView.swift` (properties after `onSeek`, mouse section)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineDrawing.swift` (`TimelinePalette`, after `marqueeFill`)
- Create: `app/NeuralSheet/UI/Timeline/RangeBandView.swift`
- Modify: `app/NeuralSheet/UI/Timeline/PianoRollView.swift` (subview + `configure`), `PianoRollView+Editing.swift` (`setRange`), `WaveformView.swift` (subview, `configure`, `setRange`)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView.swift` (`mode` didSet, `layout`, `configureViews`, stored range), `TimelineContainerView+Model.swift` (observation, snapshot, sync)

**Interfaces:**
- Consumes: `AppModel.setRange(_:)`, `model.editor.range`, `model.editor.snapEnabled`, `TempoGrid.snap(_:)`, `FillView` pattern, `CGContext.fill(_:_:)` helper in `TimelineDrawing.swift`.
- Produces: `RulerView.onRange: ((Range<Double>) -> Void)?`, `RulerView.snapEnabled: Bool`, `RangeBandView` with `var progress: Float?`, `var scale: CGFloat`, `static func place(_:range:in:geometry:)`; `PianoRollView.setRange(_ range: Range<Double>?, progress: Float?)`; `WaveformView.setRange(_ range: Range<Double>?, progress: Float?)`; `TimelinePalette.rangeFill`, `.rangeEdge`, `.rangeProgress`; container `Snapshot.range`, `.snapEnabled`, `.regionProgress` and stored `rangeOnShow: Range<Double>?`, `rangeProgressOnShow: Float?`. `regionProgress` is filled from `model.regionJob?.progress` in Task 6; until then it reads `nil` — add the snapshot field now and wire the read in Task 6.

- [ ] **Step 1: Palette**

In `TimelinePalette`, after `marqueeFill`:

```swift
    /// Region design §6.3: the marked range, its edges, and the fill that grows with a run.
    static let rangeFill = cg(Theme.accent, alpha: 0.10)
    static let rangeEdge = cg(Theme.accent, alpha: 0.6)
    static let rangeProgress = cg(Theme.accent, alpha: 0.22)
```

- [ ] **Step 2: The band view**

```swift
// RangeBandView.swift
import AppKit

/// The marked range (region design §6.3): an accent band with 1 px edges over the roll's lanes
/// and the waveform's bars, filling left to right with the region run's progress while one is in
/// flight. Positioned by its host from the geometry; repainted only when the range, the progress
/// or the frame moves. Nothing hit-tests it.
final class RangeBandView: NSView {
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { needsDisplay = true } }
    }

    /// 0…1 while a run is in flight, nil otherwise.
    var progress: Float? {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.fill(bounds, TimelinePalette.rangeFill)

        if let progress {
            let width = (bounds.width * CGFloat(min(max(progress, 0), 1))).rounded()
            ctx.fill(CGRect(x: bounds.minX, y: 0, width: width, height: bounds.height), TimelinePalette.rangeProgress)
        }

        ctx.fill(CGRect(x: bounds.minX, y: 0, width: scale, height: bounds.height), TimelinePalette.rangeEdge)
        ctx.fill(CGRect(x: bounds.maxX - scale, y: 0, width: scale, height: bounds.height), TimelinePalette.rangeEdge)
    }

    /// Lays `band` over `range` in `host`, the host's full height. The hosts' bounds origins
    /// follow their frames (`TimelineContainerView.setFrame(_:of:)`), so the geometry's x is
    /// theirs. Hidden for nil.
    static func place(_ band: RangeBandView, range: Range<Double>?, in host: NSView, geometry: TimelineGeometry) {
        guard let range else {
            band.isHidden = true
            return
        }

        let x0 = geometry.x(forSeconds: range.lowerBound)
        let x1 = geometry.x(forSeconds: range.upperBound)
        let frame = CGRect(x: x0, y: 0, width: max(x1 - x0, geometry.scale), height: host.bounds.height)

        band.isHidden = false

        if band.frame != frame {
            band.frame = frame
            band.needsDisplay = true
        }
    }
}
```

- [ ] **Step 3: The roll and the waveform host it**

`PianoRollView.swift`: after `let marquee = MarqueeView(frame: .zero)` add `let rangeBand = RangeBandView(frame: .zero)`. In `init`, add `addSubview(rangeBand)` **between** `addSubview(frontierLine)` and `addSubview(marquee)` (under the marquee and the playhead; notes are drawn in `draw`, so they read through the band's alpha). In `configure()` add `rangeBand.scale = geometry.scale`.

`PianoRollView+Editing.swift`, in the `extension PianoRollView`, add:

```swift
    // MARK: - Range

    /// The marked range and, while a region run is in flight, its progress (region design §6.3).
    func setRange(_ range: Range<Double>?, progress: Float?) {
        rangeBand.progress = progress
        RangeBandView.place(rangeBand, range: range, in: self, geometry: geometry)
    }
```

`WaveformView.swift`: after `let washEdge = FillView(...)` add `let rangeBand = RangeBandView(frame: .zero)`. In `init`, `addSubview(rangeBand)` after `addSubview(washEdge)` and before `addSubview(cornerLabel)`. In `configure()` add `rangeBand.scale = k`. Add the same `setRange(_:progress:)` method as the roll's, in a `// MARK: - Range` section after `setPlayhead`.

- [ ] **Step 4: The ruler's drag**

In `RulerView.swift`, after `var onSeek`:

```swift
    /// A drag marks a range for Re-transcribe (region design §6.2). Nil in the Transcribe tab,
    /// where the press is a seek as before.
    var onRange: ((Range<Double>) -> Void)?

    /// Whether the range's ends snap to the grid; the container mirrors the editor's setting.
    var snapEnabled = false

    /// The press's x, and whether it has travelled far enough to be a drag.
    private var pressX: CGFloat?
    private var isDragging = false

    /// Authored pixels a press may wander and still be a click.
    static let dragThreshold: CGFloat = 3
```

Replace the `mouseDown` override with:

```swift
    override func mouseDown(with event: NSEvent) {
        // A field that had the keyboard commits and lets go, so Space is the transport's again.
        window?.makeFirstResponder(nil)

        let x = convert(event.locationInWindow, from: nil).x

        guard onRange != nil else {
            // The Transcribe tab: the press is the seek, as it always was.
            onSeek?(geometry.seconds(forX: x))
            return
        }

        pressX = x
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX, onRange != nil else { return }

        let x = convert(event.locationInWindow, from: nil).x

        if !isDragging, abs(x - pressX) < RulerView.dragThreshold * geometry.scale { return }

        isDragging = true
        onRange?(range(from: pressX, to: x))
    }

    /// A press that never became a drag is the click it always was: a seek.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressX = nil
            isDragging = false
        }

        guard let pressX else { return }

        if isDragging {
            onRange?(range(from: pressX, to: convert(event.locationInWindow, from: nil).x))
        } else {
            onSeek?(geometry.seconds(forX: pressX))
        }
    }

    /// The seconds between two x's, in order, both ends snapped when the grid snaps, clamped to
    /// the take. The model refuses a sliver, so a drag that snaps to one line clears the range.
    private func range(from a: CGFloat, to b: CGFloat) -> Range<Double> {
        var lower = geometry.seconds(forX: min(a, b))
        var upper = geometry.seconds(forX: max(a, b))

        if snapEnabled, let grid {
            lower = grid.snap(lower)
            upper = grid.snap(upper)
        }

        lower = min(max(lower, 0), geometry.duration)
        upper = min(max(upper, lower), geometry.duration)

        return lower ..< upper
    }
```

Update the class doc comment's last sentence to add: "In the Edit tab a drag marks a range; a click still seeks (region design §6.2)."

- [ ] **Step 5: Container wiring**

`TimelineContainerView.swift`:

1. After `var frontierSeconds: Double?` add:
   ```swift
       /// The range and the run progress on show, so a resize or a band slide can lay the band out again.
       var rangeOnShow: Range<Double>?
       var rangeProgressOnShow: Float?
   ```
2. In the `mode` didSet block, after `roll.grid = editing ? model.editor.grid : nil`, add:
   ```swift
               ruler.onRange = editing ? { [weak self] range in self?.model.setRange(range) } : nil
               ruler.snapEnabled = editing && model.editor.snapEnabled
   ```
   and after `roll.setFrontier(seconds: frontierSeconds)` in the same block add `placeRangeBands()`.
3. In `layout()`, next to the existing `roll.setFrontier(seconds: frontierSeconds)` inside `if documentChanged || windowMoved`, add `placeRangeBands()`.
4. Add a method (near `configureViews`):
   ```swift
       /// The band over the roll and the waveform for the range on show, in the Edit tab only.
       func placeRangeBands() {
           let range = mode == .edit ? rangeOnShow : nil

           roll.setRange(range, progress: rangeProgressOnShow)
           waveform.setRange(range, progress: rangeProgressOnShow)
       }
   ```

`TimelineContainerView+Model.swift`:

1. In `Snapshot` (it is declared in `TimelineContainerView.swift`), add after `var tool: EditorState.Tool = .select`:
   ```swift
           var range: Range<Double>?
           var snapEnabled = true
           var regionProgress: Float?
   ```
2. In `observeModel()` add `_ = model.editor.range` and `_ = model.editor.snapEnabled` after `_ = model.editor.tool`.
3. In `sync()`, pass `range: model.editor.range, snapEnabled: model.editor.snapEnabled, regionProgress: nil` in the `Snapshot(...)` initialiser (Task 6 replaces `nil` with the job's progress).
4. In `sync()`, inside the `if mode == .edit {` block, add:
   ```swift
               if first || new.snapEnabled != old.snapEnabled {
                   ruler.snapEnabled = new.snapEnabled
               }
   ```
5. After the frontier block (`if stateChanged || first || new.finalizedThrough != old.finalizedThrough { … }`), add:
   ```swift
           if first || new.range != old.range || new.regionProgress != old.regionProgress || new.workspace != old.workspace {
               rangeOnShow = new.range
               rangeProgressOnShow = new.regionProgress
               placeRangeBands()
           }
   ```

- [ ] **Step 6: Build and try it**

Run the build command. Expected: succeeds, no warnings.

By hand (`/run` or Xcode): open a project with a transcription, Edit tab, drag on the ruler: a band appears over waveform and roll and follows the drag; with snap on the edges land on grid lines; click the ruler: the playhead moves, the band stays; Escape with no selection clears the band; in the Transcribe tab a ruler press seeks at once and no band shows.

- [ ] **Step 7: Commit**

```bash
git add app/NeuralSheet/UI/Timeline
git commit -m "ui: a ruler drag marks a time range, drawn as a band

In the Edit tab a drag across the ruler marks a range over the roll and
the waveform, snapped to the grid when snap is on; a click still seeks.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The region run (app)

**Files:**
- Modify: `app/NeuralSheet/App/AppModel.swift` (stored `regionJob`; guards in `clear`, `clearTranscription`, `loadAudio`; `resetTranscription`)
- Modify: `app/NeuralSheet/App/AppModel+Transcription.swift` (`failureReason` internal)
- Modify: `app/NeuralSheet/App/AppModel+Editing.swift` (`canEdit`; guards on `commit`, `undo`, `redo`, `revertToTranscription`)
- Create: `app/NeuralSheet/App/AppModel+RegionTranscription.swift`
- Modify: `app/NeuralSheet/UI/Timeline/Editing/RollEditController.swift` (`canEdit` guards)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView+Model.swift` (observe `regionJob`, pass its progress)

**Interfaces:**
- Consumes: `RegionSlice`, `NoteDocument.replace(range:with:)`, `TranscriptionEngine.run(...)`, `NoteEvent.init(engineNote:)`, `mergeOverlappingNotesWithSamePitch`, `modelStore.installedPath(for:)`, `modelSize`.
- Produces:
  ```swift
  struct AppModel.RegionJob: Equatable { range: Range<Double>; groups: [InstrumentGroup]; slice: RegionSlice; modelPath: URL; progress: Float; cancelLatched: Bool }
  var regionJob: RegionJob?                       // read by views; written by +RegionTranscription only
  var canRetranscribe: Bool
  func retranscribe(range: Range<Double>, groups: [InstrumentGroup])
  func cancelRegionTranscription()
  func setRetranscribeGroups(_ groups: [InstrumentGroup])
  func toggleRetranscribeGroup(_ group: InstrumentGroup)
  ```
  `canEdit` now also requires `regionJob == nil`.

- [ ] **Step 1: The stored job**

In `AppModel.swift`, after `var editor = EditorState()`:

```swift
    /// The region re-run in flight, or nil (`AppModel+RegionTranscription.swift`, its only
    /// writer). While it is set the editor is read-only and the clears refuse.
    var regionJob: RegionJob?
```

In `AppModel+Transcription.swift` change `private static func failureReason(` to `static func failureReason(` and add to its doc comment: "Shared with the region run's failure dialog."

- [ ] **Step 2: The run**

```swift
// AppModel+RegionTranscription.swift
import Foundation
import NeuralSheetCore

/// A run of the model over the marked range alone (region design §4.3): the slice with its
/// context, the same engine as the main run, and one "Re-transcribe" batch when it lands.
/// Nothing is applied before completion, so a cancel leaves the document exactly as it was and
/// the model's raw notes are never touched: Revert to Transcription still means the original run.
extension AppModel {
    struct RegionJob: Equatable {
        var range: Range<Double>
        /// The run's constraint; empty is Automatic.
        var groups: [InstrumentGroup]
        var slice: RegionSlice
        /// For the unsupported-version wording of the failure dialog.
        var modelPath: URL
        var progress: Float = 0
        /// From the cancel click until the engine acknowledges it at the next chunk boundary.
        var cancelLatched = false
    }

    /// The Re-transcribe button: a range, a document, a checkpoint, and no run of either kind.
    var canRetranscribe: Bool {
        state == .populated && document != nil && regionJob == nil && !jobActive
            && editor.range != nil && modelSize != nil
    }

    // MARK: - Launch

    func retranscribe(range: Range<Double>, groups: [InstrumentGroup]) {
        guard state == .populated, document != nil, regionJob == nil, !jobActive, !transcriber.isRunning else { return }
        guard let size = modelSize, let modelPath = modelStore.installedPath(for: size) else { return }
        guard let source, let slice = RegionSlice(range: range, duration: duration) else { return }

        let sampleRange = slice.sampleRange(sampleCount: source.mono16k.count)

        guard !sampleRange.isEmpty else { return }

        // A drag in progress would commit against a document about to change under it, and the
        // note card follows the selection out.
        _ = dragCanceller?()
        deselectAll()
        editor.retranscribeGroups = groups
        regionJob = RegionJob(range: range, groups: groups, slice: slice, modelPath: modelPath)

        let samples = Array(source.mono16k[sampleRange])

        // `onUpdate` and `completion` arrive on the engine's thread. A chunk is 5 s of audio, so
        // hopping each progress value onto the main actor is a handful of tasks per run; there is
        // no staging and no drain, because nothing is applied until the end.
        transcriber.run(
            modelPath: modelPath,
            groups: groups.map(\.rawValue),
            samples16k: samples,
            onUpdate: { [weak self] update in
                let progress = update.progress

                Task { @MainActor in
                    guard let self, var job = self.regionJob else { return }

                    job.progress = max(job.progress, progress)
                    self.regionJob = job
                }

                return true
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    self?.handleRegionFinished(result)
                }
            })
    }

    /// The cross on the progress group. Latched in the UI; the engine sees it at the next chunk.
    func cancelRegionTranscription() {
        guard regionJob != nil else { return }

        regionJob?.cancelLatched = true
        transcriber.cancel()
    }

    // MARK: - Completion

    /// On the main actor. A job cleared by a clear or a close ignores its completion.
    private func handleRegionFinished(_ result: Result<[EngineNote], EngineError>) {
        guard let job = regionJob else { return }

        regionJob = nil

        switch result {
        case let .success(engineNotes):
            guard var document else { return }

            let shifted = engineNotes.map { engineNote -> NoteEvent in
                var note = NoteEvent(engineNote: engineNote)
                note.startTime += job.slice.start
                note.endTime += job.slice.start

                return note
            }

            let batch = document.replace(range: job.range, with: mergeOverlappingNotesWithSamePitch(shifted))
            replaceDocumentAndCommit(document, batch)
            // The result is the selection: audition it, nudge it, or undo it at once.
            setSelection(Set(batch.inserted.map(\.id)))

        case .failure(.cancelled):
            break

        case let .failure(error):
            let reason = AppModel.failureReason(error, modelPath: job.modelPath)

            showError(
                "Transcription failed.",
                reason.isEmpty
                    ? "The transcription model could not be loaded or run."
                    : "The transcription model could not be loaded or run: \(reason).")
        }
    }

    // MARK: - The popup's instrument choice

    /// Empty is Automatic.
    func setRetranscribeGroups(_ groups: [InstrumentGroup]) {
        let normalised = AppModel.normalised(groups)

        if editor.retranscribeGroups != normalised {
            editor.retranscribeGroups = normalised
        }
    }

    func toggleRetranscribeGroup(_ group: InstrumentGroup) {
        var groups = editor.retranscribeGroups ?? []

        if groups.contains(group) {
            groups.removeAll { $0 == group }
        } else {
            groups.append(group)
        }

        setRetranscribeGroups(groups)
    }
}
```

- [ ] **Step 3: The guards**

`AppModel+Editing.swift`:

- `var canEdit: Bool { state == .populated && document != nil && regionJob == nil }`, with the comment: "Read-only while a region run owns the range (region design §4.3)."
- `commit`: `guard regionJob == nil, var document, !batch.isEmpty else { return }`
- `undo`: `guard workspace == .edit, canEdit, var document, document.canUndo else { return }`; same shape for `redo` with `canRedo`.
- `revertToTranscription`: `guard canEdit, document != nil, hasEdits else { return }`

`AppModel.swift`:

- `clear()`: `guard !jobActive, regionJob == nil else { return }`
- `clearTranscription()`: same guard.
- `loadAudio(url:)`: first line becomes `guard state == .empty || state == .audioLoaded || state == .populated, regionJob == nil else { return }`
- `resetTranscription()`: after `engine.stop()` add
  ```swift
          // A region run in flight is abandoned: its completion finds no job and does nothing.
          // `transcriber.isRunning` stays true until the engine reaches the next chunk boundary,
          // and the main run's launch refuses until then, as it does after a cancel today.
          if regionJob != nil {
              regionJob = nil
              transcriber.cancel()
          }
  ```

`RollEditController.swift`:

- At the top of `mouseDown(at:event:)`: `guard model.canEdit else { return }`
- At the top of `insertNote(at:modifiers:)`: `guard model.canEdit else { return }`
- In `cursor(at:)`: first line `guard model.canEdit else { return .arrow }`

(`mouseDragged` and `mouseUp` act only on a `session`, which `mouseDown` no longer opens; `cancelDrag` at launch closes any that existed.)

`TimelineContainerView+Model.swift`: in `observeModel()` add `_ = model.regionJob`; in `sync()` pass `regionProgress: model.regionJob?.progress`.

- [ ] **Step 4: Build**

Run the build command. Expected: succeeds, no warnings.

- [ ] **Step 5: Commit**

```bash
git add app/NeuralSheet/App app/NeuralSheet/UI/Timeline
git commit -m "app: re-run the model on the marked range as one batch

The slice with two seconds of context each side goes through the same
engine; on completion the notes starting in the range are swapped for
the run's as a \"Re-transcribe\" batch. The editor is read-only while it
runs, the clears refuse, and a close abandons it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Re-transcribe button, popup and progress (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Controls/PopupMenuPresenter.swift` (`show` gains title/footer; `refresh` keeps them)
- Modify: `app/NeuralSheet/UI/StatusBar/TranscriptionProgress.swift` (extract `ProgressGroup`)
- Create: `app/NeuralSheet/UI/Toolbar/RetranscribeButton.swift`
- Modify: `app/NeuralSheet/UI/Toolbar/EditToolbar.swift` (slot after Quantize)

**Interfaces:**
- Consumes: `model.canRetranscribe`, `model.regionJob`, `model.editor.range`, `model.editor.retranscribeGroups`, `model.setRetranscribeGroups`, `model.toggleRetranscribeGroup`, `model.retranscribe(range:groups:)`, `model.cancelRegionTranscription()`, `model.mixer.entries`, `Instruments.all`, `TimeFormat.transport`, `MenuRow`, `MenuSeparator`, `MenuSectionLabel`, `AnchorCatcher`, `FlatButton`, `Toolbar.Metrics`.
- Produces: `ProgressGroup(caption:progress:cancelling:cancelTooltip:onCancel:)`, `RetranscribeButton(model:)`, `RegionProgress(model:)`, `PopupMenuPresenter.show(from:width:scale:title:footer:rows:)`.

- [ ] **Step 1: Title and footer on the menu presenter**

In `PopupMenuPresenter.swift`:

- Add stored `private var shownTitle: String?` and `private var shownFooter: String?` after `shownScale`.
- Change `show(from:width:scale:rows:)` to
  ```swift
      func show<Rows: View>(from anchor: NSView,
                            width: CGFloat,
                            scale: CGFloat,
                            title: String? = nil,
                            footer: String? = nil,
                            @ViewBuilder rows: () -> Rows) {
  ```
  passing `title: title, footer: footer` on to the second `show`.
- Change `show(targetScreenRect:in:width:scale:placement:becomesKey:rows:)` to take `title: String? = nil, footer: String? = nil` before `rows`, store them (`shownTitle = title; shownFooter = footer`) and build `MenuPanel(title: title, footer: footer, width: width) { rows }`.
- In `refresh`, build `MenuPanel(title: shownTitle, footer: shownFooter, width: shownWidth) { rows }`.

Existing callers pass neither and are unchanged.

- [ ] **Step 2: Extract the progress group**

Rewrite `TranscriptionProgress.swift` so the pieces are a reusable view and the status bar's group is a thin wrapper. Keep `Metrics`, `caption`, `pulsePeriod`, `pulseMin`, `pulse(at:)` on `ProgressGroup`; keep `TranscriptionProgress.caption` as `"TRANSCRIBING"` for the status bar.

```swift
import SwiftUI

/// A pulsing caption, a 150 x 3 bar, the percentage and a cancel cross: the status bar's
/// transcription progress (`TranscriptionProgress`) and the Edit toolbar's region progress
/// (`RegionProgress`) are this with different words and a different cancel.
///
/// The caption pulses because it says the same thing throughout -- what it is for is to say that
/// something is still happening between two percentage ticks, which can be seconds apart. Once the
/// cross has been pressed the group dims rather than relabelling: the run is still going until the
/// engine reaches a chunk boundary, and saying otherwise would be a lie for as long as that takes.
struct ProgressGroup: View {
    let caption: String
    /// 0…1.
    let progress: Float
    let cancelling: Bool
    let cancelTooltip: String
    let onCancel: () -> Void

    @Environment(\.uiScale) private var k

    /// `nn::metrics` and `TranscriptionProgress.cpp`, authored at 1x.
    enum Metrics {
        static let barWidth: CGFloat = 150
        static let barHeight: CGFloat = 3
        static let barCorner: CGFloat = 2
        static let percentWidth: CGFloat = 28
        static let cancelHitSize: CGFloat = 16
        static let cancelGlyphSize: CGFloat = 9
        static let cancelCorner: CGFloat = 4
        static let gap: CGFloat = 10
        static let captionTracking: Double = 0.06
    }

    /// One breath in and out.
    static let pulsePeriod: TimeInterval = 1.6
    static let pulseMin: Double = 0.55

    /// The caption's alpha at a moment: a raised cosine between `pulseMin` and 1 over
    /// `pulsePeriod`, rounded to a hundredth so a pulse that has barely moved does not repaint.
    static func pulse(at seconds: TimeInterval) -> Double {
        let phase = seconds.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        let eased = 0.5 - 0.5 * cos(phase * 2 * .pi)

        return ((pulseMin + (1 - pulseMin) * eased) * 100).rounded() / 100
    }

    var body: some View {
        let s = Scaled(k: k)
        let percent = Int((100 * progress).rounded())
        let dim = cancelling ? Theme.disabledAlpha : 1

        HStack(spacing: s(Metrics.gap)) {
            SwiftUI.TimelineView(.animation(paused: cancelling)) { context in
                // The alpha is the only thing that changes per frame, and it changes at most a
                // hundredth at a time, so the text is not re-laid-out for a pulse that stood still.
                captionLabel
                    .opacity(cancelling
                        ? Theme.disabledAlpha
                        : Self.pulse(at: context.date.timeIntervalSinceReferenceDate))
            }

            bar(percent: percent, dim: dim)

            Text("\(percent)%")
                .font(Fonts.statusBar(k))
                .foregroundStyle(Theme.progressText)
                .opacity(dim)
                .lineLimit(1)
                .fixedSize()
                .frame(width: s(Metrics.percentWidth), alignment: .trailing)

            cancelButton
        }
        .fixedSize()
    }

    private var captionLabel: some View {
        TrackedLabel(string: caption,
                    em: Metrics.captionTracking,
                    pointSize: Fonts.Size.statusBar,
                    font: Fonts.statusBar(k),
                    scale: k)
            .foregroundStyle(Theme.progressText)
            .fixedSize()
    }

    private func bar(percent: Int, dim: Double) -> some View {
        let s = Scaled(k: k)
        let shape = RoundedRectangle(cornerRadius: s(Metrics.barCorner), style: .circular)
        let filled = s(Metrics.barWidth) * CGFloat(percent) / 100

        return ZStack(alignment: .leading) {
            shape.fill(Theme.progressTrack)

            if filled > 0 {
                shape.fill(Theme.progressFill)
                    .frame(width: max(filled, 2 * s(Metrics.barCorner)))
                    .opacity(dim)
            }
        }
        .frame(width: s(Metrics.barWidth), height: s(Metrics.barHeight))
    }

    /// Not disabled once cancelling: cancelling is idempotent, and a button that stops responding
    /// to the second click is a button the user has to assume is broken.
    private var cancelButton: some View {
        let s = Scaled(k: k)

        return FlatButton(idle: .clear,
                          on: Theme.bgControlActive,
                          corner: s(Metrics.cancelCorner),
                          action: onCancel) { _ in
            Icons.CrossStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.cancelGlyphSize), height: s(Metrics.cancelGlyphSize))
                .frame(width: s(Metrics.cancelHitSize), height: s(Metrics.cancelHitSize))
        }
        .tooltip(cancelTooltip)
        .accessibilityLabel(cancelTooltip)
    }
}

/// The status bar's progress group while a run is in flight (`TranscriptionProgress`).
struct TranscriptionProgress: View {
    let model: AppModel

    static let caption = "TRANSCRIBING"

    var body: some View {
        ProgressGroup(caption: Self.caption,
                      progress: model.transcriptionProgress,
                      cancelling: model.cancelLatched,
                      cancelTooltip: "Cancel transcription",
                      onCancel: model.cancelTranscription)
    }
}
```

Then grep for any other reference to `TranscriptionProgress.Metrics` or `TranscriptionProgress.pulse` (`grep -rn "TranscriptionProgress\." app/NeuralSheet`) and point them at `ProgressGroup`.

- [ ] **Step 3: The button, the popup and the region progress**

```swift
// RetranscribeButton.swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit toolbar's Re-transcribe (region design §6.4, §6.5): a label button live while a range
/// is marked, opening the popup that picks the instruments and runs; replaced in place by the
/// progress group while the run is in flight.
struct RetranscribeButton: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var menu = PopupMenuPresenter()
    @State private var anchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)

        if model.regionJob != nil {
            RegionProgress(model: model)
        } else {
            FlatButton(isEnabled: model.canRetranscribe,
                       idle: Theme.bgControlAlt,
                       on: Theme.bgControlActive,
                       foregroundIdle: Theme.textButton,
                       foregroundOn: Theme.textBright,
                       corner: s(Metrics.corner),
                       action: showMenu) { _ in
                Text("Re-transcribe")
                    .font(Fonts.buttonLabel(k))
                    .fixedSize()
                    .padding(.horizontal, s(Metrics.buttonPadX))
                    .frame(height: s(Metrics.buttonHeight))
            }
            .tooltip("Re-transcribe the marked range")
            .background(AnchorCatcher { anchor = $0 })
        }
    }

    // MARK: - Popup

    /// Preset, the first time, to the instruments in the mix; after that to what was last chosen.
    private func showMenu() {
        guard let anchor, let range = model.editor.range else { return }

        if model.editor.retranscribeGroups == nil {
            model.setRetranscribeGroups(Self.groupsInMix(model))
        }

        let titles = Instruments.all.map(\.name) + ["Automatic (any instrument)"]
        let title = "\(TimeFormat.transport(range.lowerBound)) – \(TimeFormat.transport(range.upperBound))"

        menu.show(from: anchor,
                  width: PopupMenuPresenter.width(forTitles: titles, scale: k),
                  scale: k,
                  title: title,
                  footer: "Instruments the model may use") {
            rows(range: range)
        }
    }

    /// Automatic, the mix's instruments ticked by default, the rest, then the run. Every tick
    /// re-renders the rows in place so the panel stays open, as the sidebar's picker does.
    @ViewBuilder
    private func rows(range: Range<Double>) -> some View {
        let chosen = model.editor.retranscribeGroups ?? []
        let inMix = model.mixer.entries.compactMap { entry in entry.info.group == nil ? nil : entry.info }
        let inMixGroups = Set(inMix.compactMap(\.group))
        let others = Instruments.all.filter { info in info.group.map { !inMixGroups.contains($0) } ?? false }
        let menu = menu
        let model = model

        MenuRow(title: "Automatic (any instrument)", isTicked: chosen.isEmpty) {
            model.setRetranscribeGroups([])
            refreshRows(range: range)
        }

        if !inMix.isEmpty {
            MenuSeparator()
            MenuSectionLabel(title: "IN THE MIX")

            ForEach(inMix, id: \.program) { info in
                if let group = info.group {
                    MenuRow(title: info.name, isTicked: chosen.contains(group), chip: Color(info.colour)) {
                        model.toggleRetranscribeGroup(group)
                        refreshRows(range: range)
                    }
                }
            }
        }

        MenuSeparator()
        MenuSectionLabel(title: "ALL INSTRUMENTS")

        ForEach(others, id: \.program) { info in
            if let group = info.group {
                MenuRow(title: info.name, isTicked: chosen.contains(group)) {
                    model.toggleRetranscribeGroup(group)
                    refreshRows(range: range)
                }
            }
        }

        MenuSeparator()

        MenuRow(title: "Re-transcribe") {
            menu.dismiss()
            model.retranscribe(range: range, groups: model.editor.retranscribeGroups ?? [])
        }
    }

    /// Re-renders the open panel's rows after a tick, so it shows the new ticks without closing.
    /// A method rather than a nested function: a `@ViewBuilder` body holds views, not declarations.
    private func refreshRows(range: Range<Double>) {
        menu.refresh { rows(range: range) }
    }

    /// The named groups of the instruments in the mix; a `program_<n>` has none and is skipped.
    static func groupsInMix(_ model: AppModel) -> [InstrumentGroup] {
        model.mixer.entries.compactMap(\.info.group)
    }
}

/// The toolbar's progress group while a region run is in flight (region design §6.5).
struct RegionProgress: View {
    let model: AppModel

    static let caption = "RE-TRANSCRIBING"

    var body: some View {
        ProgressGroup(caption: Self.caption,
                      progress: model.regionJob?.progress ?? 0,
                      cancelling: model.regionJob?.cancelLatched ?? false,
                      cancelTooltip: "Cancel re-transcription",
                      onCancel: model.cancelRegionTranscription)
    }
}

private extension Color {
    /// The model's colour type as SwiftUI's, for the chips. File scope, as the strip and the
    /// inspector keep their own copies: two visible overloads would collide.
    init(_ rgba: NeuralSheetCore.RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}
```

Note `MenuRow(title:isTicked:isEnabled:chip:action:)` has `action` as its last stored property, so the trailing closure works as in `EditToolbar.showDivisionMenu`.

- [ ] **Step 4: The slot on the toolbar**

In `EditToolbar.swift`, directly after `labelButton("Quantize", …)` add:

```swift
                RetranscribeButton(model: model)
```

Update the file's doc comment list to: "tools, snap and division, tempo and downbeat, Quantize, Re-transcribe, Undo/Redo, and the Drag MIDI out button the Transcribe row has."

- [ ] **Step 5: Build and try it**

Run the build command. Expected: succeeds, no warnings.

By hand: mark a range, click Re-transcribe, the popup opens titled with the range, the mix's instruments ticked; tick Automatic and the others clear; choose Re-transcribe: the button becomes the progress group, the band fills, editing is inert (clicks on the roll do nothing, the cursor is the arrow), playback still works; when it lands the notes in the range are replaced and selected, "Undo Re-transcribe" restores them. Cancel at the first chunk: nothing changes. Also confirm the status bar's own group still shows during a full transcription.

- [ ] **Step 6: Commit**

```bash
git add app/NeuralSheet/UI
git commit -m "ui: the re-transcribe button, its instrument popup and progress

The status bar's progress group becomes a shared view so the toolbar's
region progress and the transcription's do not drift.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Whole-instrument commands on the model (app)

**Files:**
- Create: `app/NeuralSheet/App/AppModel+Instruments.swift`

**Interfaces:**
- Consumes: `NoteDocument.reassign/split/deleteInstrument`, `commit`, `canEdit`, `mixer.entries`, `setTargetProgram`, `dragCanceller`.
- Produces:
  ```swift
  func reassignInstrument(_ program: Int, to destination: Int)
  func splitInstrument(_ program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int)
  func deleteInstrument(_ program: Int)
  ```

- [ ] **Step 1: Write the commands**

```swift
// AppModel+Instruments.swift
import Foundation
import NeuralSheetCore

/// The strip card's commands (region design §4.1): every note of one instrument at once, one
/// batch each. Edit tab only, and never while a region run owns the notes. No audition: these
/// move whole parts, not a note.
extension AppModel {
    /// Every note of `program` to `destination`; a merge when `destination` is already in the
    /// mix. The target follows: notes drawn next go where the part went.
    func reassignInstrument(_ program: Int, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.reassign(program: program, to: destination))

        if editor.targetProgram == program {
            setTargetProgram(destination)
        }
    }

    /// The notes of `program` at or above `pitch` (or below it) to `destination`.
    func splitInstrument(_ program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.split(program: program, atPitch: pitch, sendingAbove: sendingAbove, to: destination))
    }

    /// Every note of `program` gone. Its fader, mute and solo stay in the mixer's settings, so an
    /// undo brings the strip back as it was.
    func deleteInstrument(_ program: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.deleteInstrument(program: program))
    }

    /// The document, when the Edit tab may change it and `program` is a strip; any drag is
    /// cancelled first, since the notes under it are about to change.
    private func editableDocument(for program: Int) -> NoteDocument? {
        guard workspace == .edit, canEdit, let document,
              mixer.entries.contains(where: { $0.program == program })
        else { return nil }

        _ = dragCanceller?()

        return document
    }
}
```

- [ ] **Step 2: Build**

Run the build command. Expected: succeeds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add app/NeuralSheet/App/AppModel+Instruments.swift
git commit -m "app: reassign, split and delete a whole instrument

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The strip card (ui)

**Files:**
- Create: `app/NeuralSheet/UI/Controls/RightClickCatcher.swift`
- Create: `app/NeuralSheet/UI/Sidebar/InstrumentPicker.swift`
- Modify: `app/NeuralSheet/UI/Sidebar/SelectionFields.swift` (`showInstrumentMenu` uses the picker; `PitchField` internal)
- Create: `app/NeuralSheet/UI/Sidebar/InstrumentCard.swift`
- Modify: `app/NeuralSheet/UI/Sidebar/InstrumentStrip.swift` (`onSecondaryClick`, overlay, `==`)
- Modify: `app/NeuralSheet/UI/Sidebar/Sidebar.swift` (`StripList` presents the card)

**Interfaces:**
- Consumes: `AppModel.reassignInstrument/splitInstrument/deleteInstrument`, `canEdit`, `mixer.entries`, `PopupMenuPresenter.showPanel(at:in:scale:content:)`, `show(targetScreenRect:in:width:scale:placement:becomesKey:rows:)`, `MenuRow`, `MenuSectionLabel`, `MenuSeparator`, `PitchField(text:width:scale:onCommit:)`, `TimeFormat.pitchName`, `NoteCard.width`, `SelectionFields.rowHeight/rowGap`, `NumberField.height/corner`, `FlatButton`, `AnchorCatcher`.
- Produces:
  ```swift
  struct RightClickCatcher: NSViewRepresentable { let onRightClick: (NSWindow, CGPoint) -> Void }   // window point
  enum InstrumentPicker { @MainActor static func show(_ menu: PopupMenuPresenter, from anchor: NSView, host: PopupMenuPresenter?, model: AppModel, current: Set<Int>, excluding: Int?, scale: CGFloat, onChoose: @escaping (Int) -> Void) }
  struct InstrumentCard: View { init(model: AppModel, entry: InstrumentEntry, host: PopupMenuPresenter) }
  InstrumentStrip.onSecondaryClick: ((NSWindow, CGPoint) -> Void)?
  ```

- [ ] **Step 1: The right-click catcher**

```swift
// RightClickCatcher.swift
import AppKit
import SwiftUI

/// A transparent layer over a SwiftUI view that takes secondary presses only -- SwiftUI has no
/// right-click gesture. `hitTest` answers itself for a right button, or a Control-click, and
/// nothing otherwise, so every other event reaches whatever is under it. Reports the press in
/// window coordinates with the window, so the caller can hang a panel from it.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSWindow, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick

        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((NSWindow, CGPoint) -> Void)?

        /// Only for the event being dispatched when it is a secondary press; `point` is in the
        /// superview's coordinates, as AppKit hands it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isSecondary(event),
                  bounds.contains(convert(point, from: superview))
            else { return nil }

            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            report(event)
        }

        /// Control-click, the trackpad's secondary click on some settings.
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }

            report(event)
        }

        private func report(_ event: NSEvent) {
            guard let window else { return }

            onRightClick?(window, event.locationInWindow)
        }

        private static func isSecondary(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return true
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }
}
```

- [ ] **Step 2: The shared instrument picker**

```swift
// InstrumentPicker.swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// The instrument menu the inspector, the note card and the strip card share: the instruments
/// already in the mix first, with their colours, so moving notes onto a strip that exists is one
/// look away; then everything else.
enum InstrumentPicker {
    /// - Parameters:
    ///   - host: The popup the anchor is inside, if any. The menu is then its child and does not
    ///     take key, or the popup would close under it.
    ///   - current: Programs shown ticked (one, or none when the caller's selection disagrees).
    ///   - excluding: A program left out of the list -- the strip's own, on the strip card.
    @MainActor
    static func show(_ menu: PopupMenuPresenter,
                     from anchor: NSView,
                     host: PopupMenuPresenter?,
                     model: AppModel,
                     current: Set<Int>,
                     excluding: Int? = nil,
                     scale: CGFloat,
                     onChoose: @escaping (Int) -> Void) {
        guard let window = anchor.window else { return }

        let inMix = model.mixer.entries.map(\.info).filter { $0.program != excluding }
        let inMixPrograms = Set(inMix.map(\.program))
        let others = Instruments.all.filter { !inMixPrograms.contains($0.program) && $0.program != excluding }
        let width = PopupMenuPresenter.width(forTitles: Instruments.all.map(\.name), scale: scale)

        func row(_ info: InstrumentInfo, chip: Color?) -> MenuRow {
            MenuRow(title: info.name, isTicked: current == [info.program], chip: chip) {
                menu.dismiss()
                onChoose(info.program)
            }
        }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        host?.child = menu
        menu.show(targetScreenRect: target, in: window, width: width, scale: scale, placement: .alignedToTarget,
                  becomesKey: host == nil) {
            if !inMix.isEmpty {
                MenuSectionLabel(title: "IN THE MIX")

                ForEach(inMix, id: \.program) { info in
                    row(info, chip: Color(.sRGB, red: info.colour.r, green: info.colour.g, blue: info.colour.b, opacity: info.colour.a))
                }

                MenuSeparator()
                MenuSectionLabel(title: "ALL INSTRUMENTS")
            }

            ForEach(others, id: \.program) { info in
                row(info, chip: nil)
            }
        }
    }
}
```

In `SelectionFields.swift`, replace the body of `showInstrumentMenu()` with:

```swift
    private func showInstrumentMenu() {
        guard let anchor = instrumentAnchor else { return }

        let model = model

        InstrumentPicker.show(instrumentMenu, from: anchor, host: host, model: model,
                              current: Set(selected.map(\.program)), scale: k) { program in
            model.setSelectionProgram(program)
        }
    }
```

and delete the now-unused `private extension Color` at the bottom of `SelectionFields.swift` if nothing else in the file uses it (grep `Color(` in the file first). Change `private struct PitchField` to `struct PitchField` and note in its doc comment: "Shared with the strip card's Split field."

- [ ] **Step 3: The card**

```swift
// InstrumentCard.swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// The strip's card (region design §6.1): a right-click on a strip in the Edit tab opens the
/// whole-instrument commands at the pointer -- change every note to another instrument (the
/// merge, when that instrument is in the mix), split at a pitch, or delete the instrument. The
/// same floating panel as the roll's note card, the same rows as the inspector.
struct InstrumentCard: View {
    let model: AppModel
    let entry: InstrumentEntry
    /// The panel this card is in, so the instrument menus open as its children and a command
    /// can close it.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k
    @State private var changeMenu = PopupMenuPresenter()
    @State private var changeAnchor: NSView?
    @State private var sendMenu = PopupMenuPresenter()
    @State private var sendAnchor: NSView?
    @State private var splitPitch: Int
    @State private var sendingAbove = true
    @State private var destination: Int?

    static let width: CGFloat = NoteCard.width
    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let chipSize: CGFloat = 10
    private static let chipCorner: CGFloat = 2.5

    init(model: AppModel, entry: InstrumentEntry, host: PopupMenuPresenter) {
        self.model = model
        self.entry = entry
        self.host = host
        // The midpoint of the part's range, rounded down; middle C for a strip with no notes.
        _splitPitch = State(initialValue: entry.isPlaceholder ? 60 : (entry.lowestPitch + entry.highestPitch) / 2)
    }

    var body: some View {
        let s = Scaled(k: k)
        let colour = Color(.sRGB, red: entry.info.colour.r, green: entry.info.colour.g, blue: entry.info.colour.b, opacity: entry.info.colour.a)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: s(8)) {
                let shape = RoundedRectangle(cornerRadius: s(Self.chipCorner), style: .circular)

                ZStack {
                    shape.fill(Theme.chipFill(colour))
                    shape.strokeBorder(Theme.chipBorder(colour), lineWidth: k)
                }
                .frame(width: s(Self.chipSize), height: s(Self.chipSize))

                Text(entry.info.name.uppercased())
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.popupTitle)
                    .lineLimit(1)
            }
            .frame(height: s(Self.labelHeight), alignment: .leading)

            VStack(spacing: s(SelectionFields.rowGap)) {
                row("Change to") {
                    popupButton(title: "—") { changeAnchor = $0 } action: {
                        guard let changeAnchor else { return }

                        InstrumentPicker.show(changeMenu, from: changeAnchor, host: host, model: model, current: [],
                                              excluding: entry.program, scale: k) { program in
                            model.reassignInstrument(entry.program, to: program)
                            host.dismiss()
                        }
                    }
                }

                row("Split at") {
                    HStack(spacing: s(6)) {
                        PitchField(text: TimeFormat.pitchName(splitPitch), width: s(48), scale: k) { splitPitch = $0 }
                        sideToggle
                    }
                }

                row("Send to") {
                    popupButton(title: destination.map { Instruments.info(forProgram: $0).name } ?? "—") { sendAnchor = $0 } action: {
                        guard let sendAnchor else { return }

                        InstrumentPicker.show(sendMenu, from: sendAnchor, host: host, model: model,
                                              current: destination.map { [$0] } ?? [], excluding: entry.program, scale: k) { program in
                            destination = program
                        }
                    }
                }
            }
            .padding(.top, s(8))

            HStack(spacing: s(6)) {
                actionButton("Split", isEnabled: destination != nil, foreground: Theme.textButton) {
                    if let destination {
                        model.splitInstrument(entry.program, atPitch: splitPitch, sendingAbove: sendingAbove, to: destination)
                    }

                    host.dismiss()
                }

                actionButton("Delete instrument", isEnabled: true, foreground: Theme.warn) {
                    model.deleteInstrument(entry.program)
                    host.dismiss()
                }
            }
            .padding(.top, s(10))
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }

    // MARK: - Pieces

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(SelectionFields.rowHeight))
    }

    /// The inspector's instrument button: a flat button whose anchor the menu opens from.
    private func popupButton(title: String, anchor: @escaping (NSView) -> Void, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .lineLimit(1)
                .frame(width: s(120), height: s(NumberField.height), alignment: .leading)
                .padding(.horizontal, s(6))
        }
        .background(AnchorCatcher(found: anchor))
    }

    /// Above / Below as a two-segment pair, the live side on the accent fill.
    private var sideToggle: some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(2)) {
            segment("Above", isOn: sendingAbove) { sendingAbove = true }
            segment("Below", isOn: !sendingAbove) { sendingAbove = false }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular).fill(Theme.bgControlAlt))
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: isOn, idle: .clear, on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.accentText,
                          corner: s(NumberField.corner - 1), action: action) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .fixedSize()
                .padding(.horizontal, s(6))
                .frame(height: s(NumberField.height - 4))
        }
    }

    private func actionButton(_ title: String, isEnabled: Bool, foreground: Color, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isEnabled: isEnabled, idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: foreground, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(10))
                .frame(height: s(NumberField.height))
        }
    }
}
```

`AnchorCatcher` (`NumberField.swift`) has one stored closure, `let found: (NSView) -> Void`, hence `AnchorCatcher(found: anchor)` where the closure is passed as a value rather than trailing.

- [ ] **Step 4: The strip takes the right-click**

In `InstrumentStrip.swift`, after `var onSelect: (() -> Void)?`:

```swift
    /// A secondary click anywhere on the strip: opens the strip card in the Edit tab (region
    /// design §6.1). Nil, and no catcher is installed, in the Transcribe tab.
    var onSecondaryClick: ((NSWindow, CGPoint) -> Void)?
```

In `body`, after `.background(settings.soloed ? Theme.soloRowTint : Color.clear)` add:

```swift
        .overlay {
            if let onSecondaryClick {
                RightClickCatcher(onRightClick: onSecondaryClick)
            }
        }
```

In `==`, add `&& (lhs.onSecondaryClick == nil) == (rhs.onSecondaryClick == nil)` and extend the comment: "the two closures are compared by presence only".

- [ ] **Step 5: The strip list presents the card**

In `Sidebar.swift`, `StripList`:

```swift
    private struct StripList: View {
        let model: AppModel

        @Environment(\.uiScale) private var k
        @Environment(\.legacyScrollbarInset) private var scrollbarInset
        /// The strip card's panel, and whose strip it is up for.
        @State private var card = PopupMenuPresenter()
        @State private var cardProgram: Int?

        var body: some View {
            let editing = model.workspace == .edit

            VStack(spacing: 0) {
                ForEach(model.mixer.entries, id: \.program) { entry in
                    InstrumentStrip(model: model,
                                    entry: entry,
                                    settings: model.mixer.settings[entry.program] ?? InstrumentChannelSettings(),
                                    level: model.instrumentLevelDb(program: entry.program),
                                    width: SidebarMetrics.stripWidth - scrollbarInset / k,
                                    isTarget: editing && model.editor.targetProgram == entry.program,
                                    isHighlighted: model.highlightedProgram == entry.program,
                                    onSelect: { model.toggleHighlight(program: entry.program) },
                                    onSecondaryClick: editing ? { window, point in showCard(for: entry, in: window, at: point) } : nil)
                        .equatable()
                }
            }
            // The card is for a strip that is there and a tab that edits: gone with either.
            .onChange(of: model.mixer.entries.map(\.program)) { _, programs in
                if let cardProgram, !programs.contains(cardProgram) { card.dismiss() }
            }
            .onChange(of: model.canEdit) { _, canEdit in
                if !canEdit { card.dismiss() }
            }
            .onChange(of: model.workspace) { _, _ in
                card.dismiss()
            }
        }

        private func showCard(for entry: InstrumentEntry, in window: NSWindow, at windowPoint: CGPoint) {
            guard model.canEdit else { return }

            let card = card
            let model = model

            cardProgram = entry.program
            card.onDismiss = { cardProgram = nil }
            card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: k) {
                InstrumentCard(model: model, entry: entry, host: card)
            }
        }
    }
```

(`cardProgram = nil` inside `onDismiss` mutates `@State` from a closure: fine on the main actor, as `SelectionFields`' presenters do.)

- [ ] **Step 6: Build and try it**

Run the build command. Expected: succeeds, no warnings.

By hand: Edit tab, right-click a strip: the card opens at the pointer with the instrument's name; Change to → pick an instrument in the mix: the strip vanishes, the destination's count grows, Undo ("Undo Change Instrument") brings it back; Split at C3 Below, Send to Bass, Split: a Bass strip with the low notes; Delete instrument, then Undo: the strip returns with its fader as it was. Left-clicks on the strip still highlight/target; M, S and the fader still work. Transcribe tab: right-click does nothing. The inspector's instrument menu still works, inside the note card too.

- [ ] **Step 7: Commit**

```bash
git add app/NeuralSheet/UI
git commit -m "ui: a right-click on a strip opens the instrument card

Change every note of the instrument to another (the merge), split it at
a pitch, or delete it. The inspector's instrument menu becomes a shared
picker so the card and the note card list the mix the same way.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Docs

**Files:**
- Modify: `AGENTS.md` (line 47, the departures sentence)
- Modify: `CHANGELOG.md` (Unreleased / Added)
- Modify: `docs/design/2026-09-21-instrument-commands-and-region-retranscription-design.md` (§6.4 title format)

- [ ] **Step 1: Departures**

In `AGENTS.md`, in the "Deliberate departures so far" sentence, before "Design: `docs/design/2026-09-19-midi-editor-design.md`." insert:

```
a right-click on an instrument strip in the Edit tab opens a card that changes, splits or deletes the whole instrument; a drag on the ruler in the Edit tab marks a time range, and Re-transcribe on the Edit toolbar runs the model on that range alone, with its own instrument choice, landing as one undoable edit (design: `docs/design/2026-09-21-instrument-commands-and-region-retranscription-design.md`).
```

so the list reads "…rather than layers the width of the content; a right-click on an instrument strip… (design: …). Design: `docs/design/2026-09-19-midi-editor-design.md`."

- [ ] **Step 2: Changelog**

In `CHANGELOG.md` under `## [Unreleased]` / `### Added`, after the welcome-window line:

```
- Whole-instrument commands in the Edit tab: a right-click on a strip changes every note of the instrument to another (merging into one that exists), splits it at a pitch, or deletes it, each as one undo step.
- Re-transcribe a stretch of the take: a drag on the ruler in the Edit tab marks a range, and Re-transcribe on the toolbar runs the model on it alone, with its own choice of instruments, replacing the notes in the range as one undo step and leaving everything else as it was.
```

- [ ] **Step 3: Spec correction**

In the design doc §6.4, change "titled with the range as `mm:ss.ddd – mm:ss.ddd` (`TimeFormat`)" to "titled with the range as `mm:ss.dd – mm:ss.dd` (`TimeFormat.transport`, the transport's own readout)".

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md CHANGELOG.md docs/design/2026-09-21-instrument-commands-and-region-retranscription-design.md
git commit -m "docs: instrument commands and region re-transcription in the departures list and the changelog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Final check (after Task 10)

- `cd app/Packages/NeuralSheetCore && swift test` passes.
- The build is warning-free.
- `git status` is clean; `git log --oneline -10` shows one commit per task.
- The hand tests in §9 of the spec have been run on a real take: merge/undo, split, delete/undo, ruler drag with snap, click seeks, Escape order, region run with Piano only, cancel, close during a run, quit during a run.
