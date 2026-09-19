# MIDI Editor and Workspace Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Transcribe / Edit tab strip and a full piano-roll MIDI editor (select, move, resize, add, delete, duplicate, reassign instrument, velocity, snap, quantize, undo/redo) whose edits play back, export, and survive a relaunch.

**Architecture:** A pure `NoteDocument` value type in `NeuralSheetCore` holds identified notes and an edit-batch undo stack; `AppModel` owns one and pushes `document.events` down the existing `scheduler.swap` / piano-roll / export path after every commit. One shared AppKit `TimelineContainerView` gets a `mode`; in Edit mode a `RollEditController` turns mouse events into `EditBatch`es. The tab strip, edit toolbar and selection inspector are SwiftUI.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, AVAudioEngine, Swift Testing (`swift test`) for the core package, `xcodebuild` for the app.

**Spec:** `docs/design/2026-09-19-midi-editor-design.md`

## Global Constraints

- Build must be warning-free in our own sources: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20`.
- Core tests must pass: `cd app/Packages/NeuralSheetCore && swift test`.
- The render thread is sacred: nothing reachable from `NoteScheduler.collect` or `InstrumentSynthBank.schedule` may allocate, lock, call Objective-C properties or grow a Swift array.
- Views use the `AppModel` public contract only; never touch `transition(to:)`, `transcription`, `engine`, `synthBank` from a view.
- Files stay under ~400 lines; split with `+Extension.swift`.
- Commit messages: lowercase `area: what` (`core:`, `audio:`, `app:`, `ui:`, `docs:`), ending with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Source files are picked up by synchronized folders: never edit `project.pbxproj` to add a file.
- All authored metrics are scaled through `\.uiScale` (`Scaled(k:)`), as every existing view does.
- User-facing strings say "NeuralSheet".

---

## File structure

| File | Responsibility |
|---|---|
| `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TempoGrid.swift` (new) | `GridDivision`, `GridLine`, `TempoGrid`: snap, lines, bar.beat |
| `.../NoteDocument.swift` (new) | `NoteID`, `EditableNote`, `NoteChange`, `EditBatch`, `NoteDocument` core: init, commit, undo, redo, Codable |
| `.../NoteDocument+Commands.swift` (new) | The builders (insert … quantize) and the invariants (clamp, overlap trim) |
| `.../EditGestureMath.swift` (new) | Hit zones, move/resize resolution, drawn note, marquee |
| `.../Workspace.swift` (new) | `enum Workspace` (in Core so the session can hold it) |
| `.../NoteEvent.swift` (mod) | `velocity` accessor |
| `.../SessionState.swift` (mod) | `SessionTranscription` block and the editor settings |
| `app/NeuralSheet/Audio/NoteScheduler.swift`, `InstrumentSynthBank.swift` (mod) | Velocity byte |
| `app/NeuralSheet/App/AppModel.swift` (mod) | `workspace`, `editor`, `document`, `exportTempo` over the grid |
| `app/NeuralSheet/App/AppModel+Editing.swift` (new) | `EditorState`, the editing commands, `applyDocument`, confirm-before-discard |
| `app/NeuralSheet/App/AppModel+Transcription.swift`, `+Session.swift` (mod) | Document creation on completion; session save/restore of the transcription |
| `app/NeuralSheet/App/Dialogs.swift`, `NeuralSheetApp.swift`, `KeyboardShortcuts.swift` (mod) | Confirm dialog, Edit/View menus, editor keys |
| `app/NeuralSheet/UI/TabStrip.swift` (new), `MainView.swift` (mod) | The tab strip and the per-workspace composition |
| `app/NeuralSheet/UI/Toolbar/EditToolbar.swift` (new), `Controls/NumberField.swift` (new) | Edit-tab toolbar; the numeric field it and the inspector share |
| `app/NeuralSheet/UI/Sidebar/SelectionInspector.swift` (new), `Sidebar.swift`, `InstrumentStrip.swift` (mod) | Inspector; target rail |
| `app/NeuralSheet/UI/Timeline/TimelineGeometry.swift`, `TimelineContainerView*.swift`, `WaveformView.swift`, `RulerView.swift` (mod) | `mode`, waveform 40, ruler bars.beats + seek |
| `app/NeuralSheet/UI/Timeline/PianoRollView.swift` (mod), `PianoRollView+Editing.swift` (new) | Ids, grid, velocity alpha, selection, preview, hit test, event forwarding |
| `app/NeuralSheet/UI/Timeline/Editing/RollEditController.swift`, `+Drag.swift` (new) | Tools, drag sessions, auto-scroll |
| `app/NeuralSheet/UI/Icons.swift` (mod) | Arrow, Pencil, Eraser, Magnet, Undo, Redo, PlayheadTarget |
| `AGENTS.md`, `README.md`, `CHANGELOG.md` (mod) | Departures, usage, changelog |

---

### Task 1: `TempoGrid` (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TempoGrid.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TempoGridTests.swift`

**Interfaces:**
- Produces: `GridDivision` (`.bar, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .eighthTriplet, .sixteenthTriplet`; `label: String`, `beats: Double`), `GridLine { seconds: Double, kind: .bar | .beat | .division }`, `TempoGrid(bpm:offsetSeconds:division:)` with `secondsPerBeat`, `step`, `snap(_:)`, `snapDown(_:)`, `lines(from:to:division:)`, `barBeat(at:)`, `barBeatLabel(at:)`, `TempoGrid.minBpm = 20`, `maxBpm = 999`, `clampedBpm(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import NeuralSheetCore

@Test func divisionStepsAreFractionsOfABeat() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)
    #expect(grid.secondsPerBeat == 0.5)
    #expect(grid.step == 0.125)
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .bar).step == 2)
    #expect(abs(TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighthTriplet).step - 0.5 / 3) < 1e-12)
    #expect(abs(TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenthTriplet).step - 0.5 / 6) < 1e-12)
    #expect(GridDivision.eighthTriplet.label == "1/8T")
    #expect(GridDivision.bar.label == "1/1")
}

@Test func snapRoundsToTheNearestLineAboutTheOffset() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0.3, division: .quarter)
    #expect(abs(grid.snap(0.5) - 0.3) < 1e-12)
    #expect(abs(grid.snap(0.56) - 0.8) < 1e-12)
    #expect(abs(grid.snapDown(0.79) - 0.3) < 1e-12)
    // Never before the start of the audio.
    #expect(grid.snap(0.0) == 0)
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter).snap(0.24) == 0)
}

@Test func linesAreClassifiedAsBarBeatOrDivision() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighth)
    let lines = grid.lines(from: 0, to: 2)
    #expect(lines.count == 9)
    #expect(lines[0].kind == .bar)
    #expect(lines[1].kind == .division)
    #expect(lines[2].kind == .beat)
    #expect(lines[8].kind == .bar)
    #expect(abs(lines[8].seconds - 2) < 1e-12)

    // Nothing before 0, even when the offset puts a line there.
    let offset = TempoGrid(bpm: 120, offsetSeconds: 0.1, division: .quarter)
    #expect(offset.lines(from: 0, to: 0.2).map(\.seconds) == [0.1])

    // Triplets never land on a beat except at the beat itself.
    let triplet = TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighthTriplet)
    #expect(triplet.lines(from: 0, to: 0.5).map(\.kind) == [.bar, .division, .division, .beat])

    // The ruler asks for beats whatever the snap division is.
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .thirtySecond).lines(from: 0, to: 1, division: .quarter).count == 3)
}

@Test func barBeatCountsFromTheOffsetAndBelowIt() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 1, division: .quarter)
    #expect(grid.barBeat(at: 1) == (1, 1))
    #expect(grid.barBeat(at: 1.5) == (1, 2))
    #expect(grid.barBeat(at: 2.99) == (1, 4))
    #expect(grid.barBeat(at: 3) == (2, 1))
    #expect(grid.barBeat(at: 0.75) == (0, 4))
    #expect(grid.barBeat(at: 0) == (0, 3))
    #expect(grid.barBeatLabel(at: 3.5) == "2.2")
}

@Test func bpmIsClamped() {
    #expect(TempoGrid.clampedBpm(0) == 20)
    #expect(TempoGrid.clampedBpm(.nan) == 120)
    #expect(TempoGrid.clampedBpm(5000) == 999)
    #expect(TempoGrid.clampedBpm(96.5) == 96.5)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TempoGrid`
Expected: compile error, `TempoGrid` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How fine the snap grid is, in quarter-note beats. Raw values are stable: the session stores them.
public enum GridDivision: String, CaseIterable, Codable, Sendable {
    case bar, half, quarter, eighth, sixteenth, thirtySecond, eighthTriplet, sixteenthTriplet

    public var label: String {
        switch self {
        case .bar: "1/1"
        case .half: "1/2"
        case .quarter: "1/4"
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        case .thirtySecond: "1/32"
        case .eighthTriplet: "1/8T"
        case .sixteenthTriplet: "1/16T"
        }
    }

    /// The division's length in quarter notes.
    public var beats: Double {
        switch self {
        case .bar: 4
        case .half: 2
        case .quarter: 1
        case .eighth: 0.5
        case .sixteenth: 0.25
        case .thirtySecond: 0.125
        case .eighthTriplet: 1.0 / 3.0
        case .sixteenthTriplet: 1.0 / 6.0
        }
    }
}

/// One line of the grid, for drawing.
public struct GridLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case bar, beat, division }

    public var seconds: Double
    public var kind: Kind

    public init(seconds: Double, kind: Kind) {
        self.seconds = seconds
        self.kind = kind
    }
}

/// The editor's tempo grid: one tempo, one downbeat, 4/4 (what `MidiFileWriter` writes).
///
/// Bar 1 beat 1 falls at `offsetSeconds`; time before it is bar 0, bar −1…, so nothing is
/// unreachable. `bpm` is also the export tempo.
public struct TempoGrid: Equatable, Codable, Sendable {
    public static let minBpm = 20.0
    public static let maxBpm = 999.0
    public static let defaultBpm = 120.0
    public static let beatsPerBar = 4

    public var bpm: Double
    public var offsetSeconds: Double
    public var division: GridDivision

    public init(bpm: Double = TempoGrid.defaultBpm, offsetSeconds: Double = 0, division: GridDivision = .sixteenth) {
        self.bpm = TempoGrid.clampedBpm(bpm)
        self.offsetSeconds = max(0, offsetSeconds.isFinite ? offsetSeconds : 0)
        self.division = division
    }

    /// The rule the export tempo field had: nothing sensible is 120, everything else is clamped.
    public static func clampedBpm(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return defaultBpm }

        return min(max(bpm, minBpm), maxBpm)
    }

    public var secondsPerBeat: Double { 60 / TempoGrid.clampedBpm(bpm) }

    /// Seconds per division.
    public var step: Double { secondsPerBeat * division.beats }

    /// The nearest grid line, never before 0.
    public func snap(_ seconds: Double) -> Double {
        max(0, offsetSeconds + ((seconds - offsetSeconds) / step).rounded() * step)
    }

    /// The grid line at or before `seconds`, never before 0.
    public func snapDown(_ seconds: Double) -> Double {
        max(0, offsetSeconds + ((seconds - offsetSeconds) / step).rounded(.down) * step)
    }

    /// Every line of `division` (this grid's by default) in `from...to`, at or after 0, in order.
    public func lines(from: Double, to: Double, division: GridDivision? = nil) -> [GridLine] {
        let division = division ?? self.division
        let step = secondsPerBeat * division.beats

        guard step > 0, to >= from else { return [] }

        let first = Int(((from - offsetSeconds) / step).rounded(.up))
        let last = Int(((to - offsetSeconds) / step).rounded(.down))

        guard first <= last else { return [] }

        var lines: [GridLine] = []
        lines.reserveCapacity(last - first + 1)

        for index in first...last {
            let seconds = offsetSeconds + Double(index) * step

            guard seconds >= 0 else { continue }

            let beats = Double(index) * division.beats
            let wholeBeats = beats.rounded()
            let kind: GridLine.Kind

            if abs(beats - wholeBeats) < 1e-9 {
                kind = Int(wholeBeats) % TempoGrid.beatsPerBar == 0 ? .bar : .beat
            } else {
                kind = .division
            }

            lines.append(GridLine(seconds: seconds, kind: kind))
        }

        return lines
    }

    /// 1-based bar and beat at `seconds`; bar 0 and below before the offset.
    public func barBeat(at seconds: Double) -> (bar: Int, beat: Int) {
        let beats = ((seconds - offsetSeconds) / secondsPerBeat + 1e-9).rounded(.down)
        let barIndex = (beats / Double(TempoGrid.beatsPerBar)).rounded(.down)
        let beatInBar = Int(beats - barIndex * Double(TempoGrid.beatsPerBar))

        return (Int(barIndex) + 1, beatInBar + 1)
    }

    /// `bar.beat`, as the ruler labels it.
    public func barBeatLabel(at seconds: Double) -> String {
        let position = barBeat(at: seconds)

        return "\(position.bar).\(position.beat)"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TempoGrid`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TempoGrid.swift app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TempoGridTests.swift
git commit -m "core: TempoGrid, the editor's snap grid"
```

---

### Task 2: `NoteDocument` core — ids, batches, commit, undo, redo, Codable

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteEvent.swift` (add `velocity`)
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentTests.swift`

**Interfaces:**
- Produces: `NoteID(_ raw: Int)`, `EditableNote(id:note:)`, `NoteChange(before:after:)`, `EditBatch(title:inserted:deleted:changed:)` with `isEmpty`, `inverse`; `NoteDocument(events:)` with `notes`, `events`, `note(_:)`, `contains(_:)`, `commit(_:)`, `undo() -> EditBatch?`, `redo() -> EditBatch?`, `canUndo`, `canRedo`, `undoTitle`, `redoTitle`, `isEdited`, `NoteDocument.minimumLength = 0.010`, `NoteDocument.undoLimit = 100`, `mutating allocateID() -> NoteID`; `NoteEvent.velocity: Int`, `NoteEvent.amplitude(forVelocity:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, amplitude: Double = NoteEvent.defaultAmplitude) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

@Test func velocityIsAmplitudeTimes127ClampedTo1Through127() {
    #expect(note(0, 1, pitch: 60).velocity == 100)
    #expect(note(0, 1, pitch: 60, amplitude: 0).velocity == 1)
    #expect(note(0, 1, pitch: 60, amplitude: 1).velocity == 127)
    #expect(note(0, 1, pitch: 60, amplitude: 0.5).velocity == 64)
    #expect(NoteEvent.amplitude(forVelocity: 64) == 64.0 / 127.0)
    #expect(NoteEvent.amplitude(forVelocity: 300) == 1)
    #expect(NoteEvent.amplitude(forVelocity: -3) == 1.0 / 127.0)
}

@Test func initSortsAndNumbersTheNotes() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60), note(0, 1, pitch: 62)])
    #expect(document.notes.map(\.id.raw) == [0, 1])
    #expect(document.events == [note(0, 1, pitch: 62), note(1, 2, pitch: 60)])
    #expect(document.note(NoteID(1))?.note == note(1, 2, pitch: 60))
    #expect(document.note(NoteID(7)) == nil)
    #expect(!document.isEdited)
    #expect(!document.canUndo)
}

@Test func commitAppliesDeletesChangesAndInsertsThenSorts() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(1, 2, pitch: 62)])
    let a = document.notes[0]
    let b = document.notes[1]
    let c = EditableNote(id: document.allocateID(), note: note(0.5, 1, pitch: 64))
    let batch = EditBatch(title: "Test",
                          inserted: [c],
                          deleted: [a],
                          changed: [NoteChange(before: b, after: EditableNote(id: b.id, note: note(0.2, 2, pitch: 62)))])

    document.commit(batch)

    #expect(document.events == [note(0.2, 2, pitch: 62), note(0.5, 1, pitch: 64)])
    #expect(document.notes.map(\.id) == [b.id, c.id])
    #expect(document.isEdited)
    #expect(document.canUndo)
    #expect(document.undoTitle == "Test")
    #expect(!document.canRedo)
}

@Test func undoAndRedoRoundTrip() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let original = document.notes
    let a = document.notes[0]

    document.commit(EditBatch(title: "Move Note", changed: [NoteChange(before: a, after: EditableNote(id: a.id, note: note(3, 4, pitch: 60)))]))
    let edited = document.notes

    #expect(document.undo()?.title == "Move Note")
    #expect(document.notes == original)
    #expect(document.canRedo)
    #expect(document.redoTitle == "Move Note")
    #expect(document.isEdited, "undo-to-start does not un-edit the document")

    #expect(document.redo()?.title == "Move Note")
    #expect(document.notes == edited)
    #expect(document.undo() != nil)
    #expect(document.undo() == nil)
}

@Test func aCommitClearsRedoAndAnEmptyBatchIsIgnored() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]
    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    _ = document.undo()
    #expect(document.canRedo)

    document.commit(EditBatch(title: "Nothing"))
    #expect(document.canRedo, "an empty batch changes nothing")
    #expect(document.undoStack.isEmpty)

    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    #expect(!document.canRedo)
}

@Test func undoHistoryIsCapped() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]

    for step in 1...(NoteDocument.undoLimit + 5) {
        let before = document.notes[0]
        document.commit(EditBatch(title: "Step \(step)", changed: [NoteChange(before: before, after: EditableNote(id: a.id, note: note(Double(step), Double(step) + 1, pitch: 60)))]))
    }

    #expect(document.undoStack.count == NoteDocument.undoLimit)
    #expect(document.undoTitle == "Step \(NoteDocument.undoLimit + 5)")
}

@Test func codableKeepsNotesAndEditedFlagButNotHistory() throws {
    var document = NoteDocument(events: [note(0, 1, pitch: 60)])
    let a = document.notes[0]
    document.commit(EditBatch(title: "Delete Note", deleted: [a]))
    let inserted = EditableNote(id: document.allocateID(), note: note(2, 3, pitch: 61))
    document.commit(EditBatch(title: "Add Note", inserted: [inserted]))

    let data = try JSONEncoder().encode(document)
    var decoded = try JSONDecoder().decode(NoteDocument.self, from: data)

    #expect(decoded.notes == document.notes)
    #expect(decoded.isEdited)
    #expect(!decoded.canUndo)
    #expect(!decoded.canRedo)
    // The id counter survives, so a new note never collides with a restored one.
    #expect(decoded.allocateID().raw > inserted.id.raw)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter NoteDocument`
Expected: compile error, `NoteDocument` / `velocity` not found.

- [ ] **Step 3: Add `velocity` to `NoteEvent`**

In `NoteEvent.swift`, inside `public struct NoteEvent`, after `isDrum`:

```swift
    /// The MIDI velocity this note's amplitude stands for, 1…127. The model gives every note
    /// 100; the editor sets others.
    public var velocity: Int {
        min(max(Int((amplitude * 127).rounded()), 1), 127)
    }

    /// The amplitude that reads back as `velocity`, clamped to 1…127.
    public static func amplitude(forVelocity velocity: Int) -> Double {
        Double(min(max(velocity, 1), 127)) / 127.0
    }
```

- [ ] **Step 4: Implement `NoteDocument.swift`**

```swift
import Foundation

/// A note's identity inside one ``NoteDocument``: what a selection and an undo batch refer to,
/// which an array index cannot be, since the notes are re-sorted after every edit.
public struct NoteID: Hashable, Comparable, Codable, Sendable {
    public let raw: Int

    public init(_ raw: Int) {
        self.raw = raw
    }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool {
        lhs.raw < rhs.raw
    }
}

/// A note with its identity.
public struct EditableNote: Equatable, Hashable, Codable, Sendable {
    public var id: NoteID
    public var note: NoteEvent

    public init(id: NoteID, note: NoteEvent) {
        self.id = id
        self.note = note
    }
}

/// One note before and after an edit. A struct rather than a tuple so the batch is `Codable`.
public struct NoteChange: Equatable, Codable, Sendable {
    public var before: EditableNote
    public var after: EditableNote

    public init(before: EditableNote, after: EditableNote) {
        self.before = before
        self.after = after
    }
}

/// One undoable edit: the notes it adds, the notes it removes and the notes it changes. Every
/// command in the editor is expressed as one of these; its inverse is the same struct with the
/// roles swapped, which is the whole undo model.
public struct EditBatch: Equatable, Codable, Sendable {
    /// "Move Notes", "Delete Note"…: what the Undo menu item says.
    public var title: String
    public var inserted: [EditableNote]
    public var deleted: [EditableNote]
    public var changed: [NoteChange]

    public init(title: String, inserted: [EditableNote] = [], deleted: [EditableNote] = [], changed: [NoteChange] = []) {
        self.title = title
        self.inserted = inserted
        self.deleted = deleted
        self.changed = changed
    }

    public var isEmpty: Bool { inserted.isEmpty && deleted.isEmpty && changed.isEmpty }

    public var inverse: EditBatch {
        EditBatch(title: title,
                  inserted: deleted,
                  deleted: inserted,
                  changed: changed.map { NoteChange(before: $0.after, after: $0.before) })
    }
}

/// The editable transcription: identified notes kept in `NoteEvent` order, and the undo and redo
/// stacks of batches that got them there.
///
/// `events` is what the piano roll draws, the scheduler plays and the export writes; nothing
/// downstream of the document knows about ids or history. The history is not encoded: a restored
/// session starts with no undo, but keeps `isEdited` so the app still knows the notes are not the
/// model's own.
public struct NoteDocument: Equatable, Codable, Sendable {
    /// The shortest note an edit can leave behind, in seconds.
    public static let minimumLength = 0.010
    /// Batches kept for undo.
    public static let undoLimit = 100

    /// Sorted by `NoteEvent.<`, ties broken by id.
    public private(set) var notes: [EditableNote]
    public private(set) var undoStack: [EditBatch] = []
    public private(set) var redoStack: [EditBatch] = []
    /// True once any batch has been committed. Survives undo-to-empty; cleared only by making a
    /// new document.
    public private(set) var isEdited = false
    private var nextID: Int

    public init(events: [NoteEvent]) {
        let sorted = events.sorted()
        notes = sorted.enumerated().map { EditableNote(id: NoteID($0.offset), note: $0.element) }
        nextID = sorted.count
    }

    // MARK: - Reading

    public var events: [NoteEvent] { notes.map(\.note) }

    public func note(_ id: NoteID) -> EditableNote? {
        notes.first { $0.id == id }
    }

    public func contains(_ id: NoteID) -> Bool {
        notes.contains { $0.id == id }
    }

    /// Index by id, built once per batch rather than searched per note.
    func indexByID() -> [NoteID: Int] {
        var map: [NoteID: Int] = [:]
        map.reserveCapacity(notes.count)

        for (index, note) in notes.enumerated() {
            map[note.id] = index
        }

        return map
    }

    /// A fresh id for a note about to be inserted. Taking one without committing is harmless.
    public mutating func allocateID() -> NoteID {
        defer { nextID += 1 }

        return NoteID(nextID)
    }

    // MARK: - History

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoTitle: String? { undoStack.last?.title }
    public var redoTitle: String? { redoStack.last?.title }

    /// Applies the batch, records it, and drops whatever could have been redone.
    public mutating func commit(_ batch: EditBatch) {
        guard !batch.isEmpty else { return }

        apply(batch)
        undoStack.append(batch)

        if undoStack.count > NoteDocument.undoLimit {
            undoStack.removeFirst(undoStack.count - NoteDocument.undoLimit)
        }

        redoStack.removeAll()
        isEdited = true
    }

    /// The batch undone, for the menu title; nil with nothing to undo.
    @discardableResult
    public mutating func undo() -> EditBatch? {
        guard let batch = undoStack.popLast() else { return nil }

        apply(batch.inverse)
        redoStack.append(batch)

        return batch
    }

    @discardableResult
    public mutating func redo() -> EditBatch? {
        guard let batch = redoStack.popLast() else { return nil }

        apply(batch)
        undoStack.append(batch)

        return batch
    }

    /// Deletions and changes by id, then the insertions, then one sort.
    private mutating func apply(_ batch: EditBatch) {
        let deleted = Set(batch.deleted.map(\.id))
        var changes: [NoteID: EditableNote] = [:]

        for change in batch.changed {
            changes[change.after.id] = change.after
        }

        var result: [EditableNote] = []
        result.reserveCapacity(notes.count + batch.inserted.count)

        for note in notes where !deleted.contains(note.id) {
            result.append(changes[note.id] ?? note)
        }

        result.append(contentsOf: batch.inserted)
        result.sort(by: NoteDocument.ordered)
        notes = result
    }

    /// `NoteEvent.<` — which ignores amplitude — with the id as the final tie-break, so the order
    /// is total and two saves of one document give one file.
    static func ordered(_ lhs: EditableNote, _ rhs: EditableNote) -> Bool {
        if lhs.note < rhs.note { return true }
        if rhs.note < lhs.note { return false }

        return lhs.id < rhs.id
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case notes, isEdited, nextID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([EditableNote].self, forKey: .notes)
        notes = decoded.sorted(by: NoteDocument.ordered)
        isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        nextID = try container.decodeIfPresent(Int.self, forKey: .nextID)
            ?? ((decoded.map(\.id.raw).max() ?? -1) + 1)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notes, forKey: .notes)
        try container.encode(isEdited, forKey: .isEdited)
        try container.encode(nextID, forKey: .nextID)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test`
Expected: all pass, including the existing suites.

- [ ] **Step 6: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: NoteDocument with edit-batch undo; NoteEvent.velocity"
```

---

### Task 3: `NoteDocument` commands and invariants

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/NoteDocument+Commands.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/NoteDocumentCommandTests.swift`

**Interfaces:**
- Consumes: Task 1's `TempoGrid`, Task 2's types.
- Produces: `NoteEdge` (`.start`, `.end`); on `NoteDocument`: `mutating insert(_:) -> EditBatch`, `mutating duplicate(_:deltaSeconds:deltaSemitones:)`, `delete(_:)`, `move(_:deltaSeconds:deltaSemitones:)`, `resize(_:edge:deltaSeconds:)`, `setStart(_:seconds:)`, `setLength(_:seconds:)`, `setPitch(_:pitch:)`, `setProgram(_:program:)`, `setVelocity(_:velocity:)`, `quantize(_:grid:lengths:)`; all take `Set<NoteID>` and return an `EditBatch` ready for `commit`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, pitch: Int, program: Int = 0, amplitude: Double = NoteEvent.defaultAmplitude) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Test func insertAllocatesAnIdAndClampsTheNote() {
    var document = NoteDocument(events: [])
    let batch = document.insert(note(-1, -0.5, pitch: 200, program: 300, amplitude: 4))
    document.commit(batch)

    #expect(batch.title == "Add Note")
    #expect(document.notes.count == 1)
    let inserted = document.notes[0].note
    #expect(inserted.startTime == 0)
    #expect(near(inserted.endTime, NoteDocument.minimumLength))
    #expect(inserted.pitch == 127)
    #expect(inserted.program == 127)
    #expect(inserted.amplitude == 1)
}

@Test func deleteAndDuplicate() {
    var document = NoteDocument(events: [note(0, 1, pitch: 60), note(2, 3, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    let copies = document.duplicate(ids, deltaSeconds: 4, deltaSemitones: 12)
    #expect(copies.title == "Duplicate Notes")
    #expect(copies.inserted.map(\.note) == [note(4, 5, pitch: 72), note(6, 7, pitch: 74)])
    #expect(Set(copies.inserted.map(\.id)).isDisjoint(with: ids))

    let removal = document.delete(ids)
    #expect(removal.title == "Delete Notes")
    document.commit(removal)
    #expect(document.notes.isEmpty)
    #expect(document.delete([]).isEmpty)
}

@Test func moveKeepsRelativeSpacingWhenClampedAtZeroAndAtThePitchEdges() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60), note(3, 4, pitch: 70)])
    let ids = Set(document.notes.map(\.id))

    let batch = document.move(ids, deltaSeconds: -5, deltaSemitones: 60)
    #expect(batch.title == "Move Notes")
    let after = batch.changed.map(\.after.note).sorted()
    // The earliest note stops at 0, and the whole selection moves by that reduced delta.
    #expect(after == [note(0, 1, pitch: 117), note(2, 3, pitch: 127)])

    let single = document.move([document.notes[0].id], deltaSeconds: 0.5, deltaSemitones: -1)
    #expect(single.title == "Move Note")
    #expect(single.changed[0].after.note == note(1.5, 2.5, pitch: 59))
    #expect(document.move(ids, deltaSeconds: 0, deltaSemitones: 0).isEmpty)
}

@Test func resizeStopsAtTheOtherEdgeAndAtZero() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60)])
    let id = document.notes[0].id

    let longer = document.resize([id], edge: .end, deltaSeconds: 1.5)
    #expect(longer.title == "Resize Note")
    #expect(longer.changed[0].after.note == note(1, 3.5, pitch: 60))

    let collapsed = document.resize([id], edge: .end, deltaSeconds: -5)
    #expect(near(collapsed.changed[0].after.note.endTime, 1 + NoteDocument.minimumLength))

    let earlier = document.resize([id], edge: .start, deltaSeconds: -5)
    #expect(earlier.changed[0].after.note == note(0, 2, pitch: 60))

    let crossed = document.resize([id], edge: .start, deltaSeconds: 5)
    #expect(near(crossed.changed[0].after.note.startTime, 2 - NoteDocument.minimumLength))
}

@Test func absoluteSetters() {
    let document = NoteDocument(events: [note(1, 2, pitch: 60, amplitude: 0.5), note(3, 4, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    #expect(document.setStart(ids, seconds: 5).changed.map(\.after.note).sorted() == [note(5, 6, pitch: 60, amplitude: 0.5), note(5, 6, pitch: 62)])
    #expect(document.setLength(ids, seconds: 0.25).changed.map(\.after.note).sorted() == [note(1, 1.25, pitch: 60, amplitude: 0.5), note(3, 3.25, pitch: 62)])
    #expect(document.setPitch(ids, pitch: 40).changed.map(\.after.note.pitch) == [40, 40])
    #expect(document.setProgram(ids, program: NoteEvent.drumProgram).changed.map(\.after.note.program) == [128, 128])
    #expect(document.setProgram(ids, program: 500).changed.map(\.after.note.program) == [127, 127])

    let velocity = document.setVelocity(ids, velocity: 64)
    #expect(velocity.title == "Set Velocity")
    #expect(velocity.changed.map(\.after.note.velocity) == [64, 64])
    #expect(document.setVelocity(ids, velocity: 100).changed.count == 1, "the note already at 100 is not a change")
}

@Test func quantizeSnapsStartsAndOptionallyLengths() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)   // step 0.5
    let document = NoteDocument(events: [note(0.6, 1.3, pitch: 60), note(2.3, 2.35, pitch: 62)])
    let ids = Set(document.notes.map(\.id))

    let starts = document.quantize(ids, grid: grid, lengths: false)
    #expect(starts.title == "Quantize")
    let a = starts.changed.map(\.after.note).sorted()
    #expect(near(a[0].startTime, 0.5) && near(a[0].endTime, 1.2))
    #expect(near(a[1].startTime, 2.5) && near(a[1].endTime, 2.55))

    let both = document.quantize(ids, grid: grid, lengths: true)
    let b = both.changed.map(\.after.note).sorted()
    #expect(near(b[0].endTime, 1.0))
    #expect(near(b[1].endTime, 3.0), "never shorter than one division")
}

@Test func overlapOnOneInstrumentAndPitchTrimsTheEarlierNote() {
    var document = NoteDocument(events: [note(0, 2, pitch: 60), note(3, 4, pitch: 60), note(0, 2, pitch: 60, program: 5)])
    let later = document.notes.first { $0.note.startTime == 3 }!

    // Moving the later note back to 1 s overlaps the first: the first is trimmed to end at 1.
    let batch = document.move([later.id], deltaSeconds: -2, deltaSemitones: 0)
    #expect(batch.changed.count == 2)
    document.commit(batch)
    #expect(document.events == [note(0, 1, pitch: 60), note(0, 2, pitch: 60, program: 5), note(1, 2, pitch: 60)])

    // The other instrument's note on the same pitch is untouched, and the trim undoes with the move.
    document.undo()
    #expect(document.events == [note(0, 2, pitch: 60), note(0, 2, pitch: 60, program: 5), note(3, 4, pitch: 60)])

    // Touching notes do not overlap.
    let touching = document.move([later.id], deltaSeconds: -1, deltaSemitones: 0)
    #expect(touching.changed.count == 1)
}

@Test func overlapThatWouldLeaveNothingDeletesTheEarlierNote() {
    var document = NoteDocument(events: [note(1, 2, pitch: 60), note(3, 4, pitch: 60)])
    let first = document.notes[0]
    let second = document.notes[1]

    // The second note dropped exactly onto the first: the first cannot be trimmed to 10 ms.
    document.commit(document.move([second.id], deltaSeconds: -2, deltaSemitones: 0))
    #expect(document.notes.map(\.id) == [second.id])
    #expect(document.events == [note(1, 2, pitch: 60)])

    document.undo()
    #expect(document.notes.map(\.id) == [first.id, second.id])
}

@Test func insertingOverAnExistingNoteTrimsIt() {
    var document = NoteDocument(events: [note(0, 4, pitch: 60)])
    document.commit(document.insert(note(1, 2, pitch: 60)))
    #expect(document.events == [note(0, 1, pitch: 60), note(1, 2, pitch: 60)])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter NoteDocumentCommand`
Expected: compile errors for the missing builders.

- [ ] **Step 3: Implement `NoteDocument+Commands.swift`**

```swift
import Foundation

/// Which end of a note a resize takes hold of.
public enum NoteEdge: Equatable, Sendable {
    case start, end
}

/// The editor's commands. Each builds the ``EditBatch`` that ``NoteDocument/commit(_:)`` applies,
/// already run through the invariants (§4.4 of the design): every note in it is clamped, and any
/// same-instrument same-pitch overlap the edit would create is resolved inside the same batch, so
/// it undoes with it.
extension NoteDocument {
    // MARK: - Builders

    public mutating func insert(_ note: NoteEvent) -> EditBatch {
        let inserted = EditableNote(id: allocateID(), note: note)

        return finished(EditBatch(title: "Add Note", inserted: [inserted]))
    }

    public mutating func duplicate(_ ids: Set<NoteID>, deltaSeconds: Double, deltaSemitones: Int) -> EditBatch {
        let sources = selected(ids)
        var copies: [EditableNote] = []

        for source in sources {
            copies.append(EditableNote(id: allocateID(), note: NoteDocument.shifted(source.note, by: deltaSeconds, semitones: deltaSemitones)))
        }

        return finished(EditBatch(title: NoteDocument.title("Duplicate", count: copies.count), inserted: copies))
    }

    public func delete(_ ids: Set<NoteID>) -> EditBatch {
        let doomed = selected(ids)

        return EditBatch(title: NoteDocument.title("Delete", count: doomed.count), deleted: doomed)
    }

    /// The whole selection moves by one delta, reduced so the earliest note stops at 0 and no
    /// pitch leaves 0…127 — relative spacing is kept rather than notes piling up at the edge.
    public func move(_ ids: Set<NoteID>, deltaSeconds: Double, deltaSemitones: Int) -> EditBatch {
        let sources = selected(ids)

        guard !sources.isEmpty else { return EditBatch(title: "Move Note") }

        let earliest = sources.map(\.note.startTime).min() ?? 0
        let lowest = sources.map(\.note.pitch).min() ?? 0
        let highest = sources.map(\.note.pitch).max() ?? 127
        let seconds = max(deltaSeconds, -earliest)
        let semitones = min(max(deltaSemitones, -lowest), 127 - highest)

        return changing(sources, title: NoteDocument.title("Move", count: sources.count)) {
            NoteDocument.shifted($0, by: seconds, semitones: semitones)
        }
    }

    public func resize(_ ids: Set<NoteID>, edge: NoteEdge, deltaSeconds: Double) -> EditBatch {
        let sources = selected(ids)

        return changing(sources, title: NoteDocument.title("Resize", count: sources.count)) { note in
            var note = note

            switch edge {
            case .start:
                note.startTime = min(max(note.startTime + deltaSeconds, 0), note.endTime - NoteDocument.minimumLength)
            case .end:
                note.endTime = max(note.endTime + deltaSeconds, note.startTime + NoteDocument.minimumLength)
            }

            return note
        }
    }

    public func setStart(_ ids: Set<NoteID>, seconds: Double) -> EditBatch {
        changing(selected(ids), title: "Set Start") { note in
            NoteDocument.shifted(note, by: max(0, seconds) - note.startTime, semitones: 0)
        }
    }

    public func setLength(_ ids: Set<NoteID>, seconds: Double) -> EditBatch {
        changing(selected(ids), title: "Set Length") { note in
            var note = note
            note.endTime = note.startTime + max(seconds, NoteDocument.minimumLength)

            return note
        }
    }

    public func setPitch(_ ids: Set<NoteID>, pitch: Int) -> EditBatch {
        changing(selected(ids), title: "Set Pitch") { note in
            var note = note
            note.pitch = pitch

            return note
        }
    }

    public func setProgram(_ ids: Set<NoteID>, program: Int) -> EditBatch {
        changing(selected(ids), title: "Change Instrument") { note in
            var note = note
            note.program = program

            return note
        }
    }

    public func setVelocity(_ ids: Set<NoteID>, velocity: Int) -> EditBatch {
        changing(selected(ids), title: "Set Velocity") { note in
            var note = note
            note.amplitude = NoteEvent.amplitude(forVelocity: velocity)

            return note
        }
    }

    /// Starts to the nearest line; with `lengths`, lengths to the nearest whole number of
    /// divisions, never under one.
    public func quantize(_ ids: Set<NoteID>, grid: TempoGrid, lengths: Bool) -> EditBatch {
        changing(selected(ids), title: "Quantize") { note in
            var note = NoteDocument.shifted(note, by: grid.snap(note.startTime) - note.startTime, semitones: 0)

            if lengths {
                let divisions = max(1, ((note.endTime - note.startTime) / grid.step).rounded())
                note.endTime = note.startTime + divisions * grid.step
            }

            return note
        }
    }

    // MARK: - Helpers

    private func selected(_ ids: Set<NoteID>) -> [EditableNote] {
        notes.filter { ids.contains($0.id) }
    }

    private static func title(_ verb: String, count: Int) -> String {
        count == 1 ? "\(verb) Note" : "\(verb) Notes"
    }

    static func shifted(_ note: NoteEvent, by seconds: Double, semitones: Int) -> NoteEvent {
        var note = note
        note.startTime += seconds
        note.endTime += seconds
        note.pitch += semitones

        return note
    }

    /// A change per note the transform actually changes.
    private func changing(_ sources: [EditableNote], title: String, _ transform: (NoteEvent) -> NoteEvent) -> EditBatch {
        var batch = EditBatch(title: title)

        for source in sources {
            let after = transform(source.note)

            if after != source.note {
                batch.changed.append(NoteChange(before: source, after: EditableNote(id: source.id, note: after)))
            }
        }

        return finished(batch)
    }

    // MARK: - Invariants

    /// Clamps every note the batch introduces, then resolves the overlaps it creates.
    private func finished(_ batch: EditBatch) -> EditBatch {
        var batch = batch
        batch.inserted = batch.inserted.map { EditableNote(id: $0.id, note: NoteDocument.clamped($0.note)) }
        batch.changed = batch.changed.map { NoteChange(before: $0.before, after: EditableNote(id: $0.after.id, note: NoteDocument.clamped($0.after.note))) }

        return resolvingOverlaps(batch)
    }

    static func clamped(_ note: NoteEvent) -> NoteEvent {
        var note = note
        note.pitch = min(max(note.pitch, 0), 127)
        note.program = note.program == NoteEvent.drumProgram ? note.program : min(max(note.program, 0), 127)
        note.amplitude = note.amplitude.isFinite ? min(max(note.amplitude, 1.0 / 127.0), 1) : NoteEvent.defaultAmplitude
        note.startTime = note.startTime.isFinite ? max(note.startTime, 0) : 0
        note.endTime = note.endTime.isFinite ? max(note.endTime, note.startTime + minimumLength) : note.startTime + minimumLength

        return note
    }

    /// Projects the batch onto the notes, then walks every instrument-and-pitch group the batch
    /// touched: an earlier note overlapping a later one is trimmed to end where the later starts,
    /// or deleted when the trim would leave less than ``minimumLength``. The document never holds
    /// an overlap between commits, so only groups the batch touches can have one.
    private func resolvingOverlaps(_ batch: EditBatch) -> EditBatch {
        struct Key: Hashable {
            var program: Int
            var pitch: Int
        }

        var batch = batch
        let deleted = Set(batch.deleted.map(\.id))
        var projected: [NoteID: EditableNote] = [:]

        for note in notes where !deleted.contains(note.id) {
            projected[note.id] = note
        }

        for change in batch.changed {
            projected[change.after.id] = change.after
        }

        for note in batch.inserted {
            projected[note.id] = note
        }

        let touched = Set(batch.changed.map { Key(program: $0.after.note.program, pitch: $0.after.note.pitch) }
            + batch.inserted.map { Key(program: $0.note.program, pitch: $0.note.pitch) })

        guard !touched.isEmpty else { return batch }

        var groups: [Key: [EditableNote]] = [:]

        for note in projected.values {
            let key = Key(program: note.note.program, pitch: note.note.pitch)

            if touched.contains(key) {
                groups[key, default: []].append(note)
            }
        }

        // Per group, in start order: each note may only be cut by the one after it.
        for (_, group) in groups {
            let ordered = group.sorted(by: NoteDocument.ordered)

            for index in ordered.indices.dropLast() {
                let earlier = ordered[index]
                let later = ordered[index + 1]

                guard earlier.note.endTime > later.note.startTime else { continue }

                if later.note.startTime - earlier.note.startTime >= NoteDocument.minimumLength {
                    var trimmed = earlier.note
                    trimmed.endTime = later.note.startTime
                    record(EditableNote(id: earlier.id, note: trimmed), in: &batch)
                } else {
                    remove(earlier, from: &batch)
                }
            }
        }

        return batch
    }

    /// A trimmed note replaces its own entry in the batch, or becomes a new change.
    private func record(_ trimmed: EditableNote, in batch: inout EditBatch) {
        if let index = batch.inserted.firstIndex(where: { $0.id == trimmed.id }) {
            batch.inserted[index] = trimmed
        } else if let index = batch.changed.firstIndex(where: { $0.after.id == trimmed.id }) {
            batch.changed[index].after = trimmed
        } else if let original = note(trimmed.id) {
            batch.changed.append(NoteChange(before: original, after: trimmed))
        }
    }

    /// A note the trim would erase: an inserted one is simply not inserted, a changed one is
    /// deleted from its original, an untouched one is deleted as it is.
    private func remove(_ doomed: EditableNote, from batch: inout EditBatch) {
        if let index = batch.inserted.firstIndex(where: { $0.id == doomed.id }) {
            batch.inserted.remove(at: index)
        } else if let index = batch.changed.firstIndex(where: { $0.after.id == doomed.id }) {
            let original = batch.changed[index].before
            batch.changed.remove(at: index)
            batch.deleted.append(original)
        } else if let original = note(doomed.id) {
            batch.deleted.append(original)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test`
Expected: all pass. If `overlapThatWouldLeaveNothingDeletesTheEarlierNote` fails on `notes.map(\.id) == [second.id]`: the moved note and the first note have equal start, program, pitch and end, so `ordered` falls back to id — the first (lower id) is "earlier" and is the one removed. That is the intended rule.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: NoteDocument commands, clamping and same-pitch overlap resolution"
```

---
### Task 4: `EditGestureMath` (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/EditGestureMath.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/EditGestureMathTests.swift`

**Interfaces:**
- Consumes: `TempoGrid`, `NoteID`.
- Produces: `NoteHitZone` (`.body, .startEdge, .endEdge`), `AxisLock` (`.timeOnly, .pitchOnly`), `EditGestureMath.hitZone(in:at:edgeWidth:minimumWidthForEdges:)`, `axisLock(deltaX:deltaY:)`, `resolveMove(deltaSeconds:deltaSemitones:anchorStart:grid:axisLock:)`, `resolveResize(deltaSeconds:anchorEdgeTime:grid:)`, `drawnNote(anchor:current:grid:snapEnabled:)`, `marqueeSelection(_:notes:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Testing

@testable import NeuralSheetCore

@Test func hitZonesAreTheOuterEdgesOfWideNotesOnly() {
    let rect = CGRect(x: 100, y: 10, width: 40, height: 8)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 103, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .startEdge)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 137, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .endEdge)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 120, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .body)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 120, y: 30), edgeWidth: 6, minimumWidthForEdges: 14) == nil)

    let narrow = CGRect(x: 100, y: 10, width: 10, height: 8)
    #expect(EditGestureMath.hitZone(in: narrow, at: CGPoint(x: 101, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .body)
}

@Test func moveSnapsTheAnchorAndLocksAnAxis() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)   // 0.5 s
    let snapped = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: grid, axisLock: nil)
    #expect(abs(snapped.seconds - 0.4) < 1e-9, "1.1 + 0.3 = 1.4 snaps to 1.5")
    #expect(snapped.semitones == 2)

    let free = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: nil)
    #expect(free.seconds == 0.3)

    let timeOnly = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: .timeOnly)
    #expect(timeOnly.semitones == 0 && timeOnly.seconds == 0.3)

    let pitchOnly = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: .pitchOnly)
    #expect(pitchOnly.seconds == 0 && pitchOnly.semitones == 2)

    #expect(EditGestureMath.axisLock(deltaX: 10, deltaY: 3) == .timeOnly)
    #expect(EditGestureMath.axisLock(deltaX: 2, deltaY: 30) == .pitchOnly)
}

@Test func resizeSnapsTheDraggedEdge() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)
    #expect(abs(EditGestureMath.resolveResize(deltaSeconds: 0.2, anchorEdgeTime: 2.0, grid: grid) - 0) < 1e-9)
    #expect(abs(EditGestureMath.resolveResize(deltaSeconds: 0.3, anchorEdgeTime: 2.0, grid: grid) - 0.5) < 1e-9)
    #expect(EditGestureMath.resolveResize(deltaSeconds: 0.3, anchorEdgeTime: 2.0, grid: nil) == 0.3)
}

@Test func drawnNoteStartsOnTheLineBeforeTheClickAndIsAtLeastOneDivision() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)
    let click = EditGestureMath.drawnNote(anchor: 1.3, current: 1.3, grid: grid, snapEnabled: true)
    #expect(abs(click.start - 1.0) < 1e-9 && abs(click.end - 1.5) < 1e-9)

    let dragged = EditGestureMath.drawnNote(anchor: 1.3, current: 2.4, grid: grid, snapEnabled: true)
    #expect(abs(dragged.end - 2.5) < 1e-9)

    let backwards = EditGestureMath.drawnNote(anchor: 1.3, current: 0.2, grid: grid, snapEnabled: true)
    #expect(abs(backwards.end - 1.5) < 1e-9)

    let unsnapped = EditGestureMath.drawnNote(anchor: 1.3, current: 1.3, grid: grid, snapEnabled: false)
    #expect(unsnapped.start == 1.3 && abs(unsnapped.end - 1.8) < 1e-9)
}

@Test func marqueeSelectsEveryIntersectingNote() {
    let notes: [(id: NoteID, rect: CGRect)] = [
        (NoteID(0), CGRect(x: 0, y: 0, width: 10, height: 5)),
        (NoteID(1), CGRect(x: 8, y: 0, width: 10, height: 5)),
        (NoteID(2), CGRect(x: 50, y: 50, width: 10, height: 5)),
    ]
    let rect = CGRect(x: 9, y: 1, width: 20, height: 20)
    #expect(EditGestureMath.marqueeSelection(rect, notes: notes) == [NoteID(0), NoteID(1)])

    // A marquee dragged up-and-left is the same rectangle.
    let flipped = CGRect(x: 29, y: 21, width: -20, height: -20)
    #expect(EditGestureMath.marqueeSelection(flipped, notes: notes) == [NoteID(0), NoteID(1)])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter EditGestureMath`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Foundation

/// Where on a note the pointer landed.
public enum NoteHitZone: Equatable, Sendable {
    case body, startEdge, endEdge
}

/// The axis a ⇧-drag keeps.
public enum AxisLock: Equatable, Sendable {
    case timeOnly, pitchOnly
}

/// The decisions the roll's edit controller makes, as pure functions of geometry and the grid, so
/// they can be tested without a view.
public enum EditGestureMath {
    /// The zone under `point`, or nil outside the rect. Edges exist only on notes at least
    /// `minimumWidthForEdges` wide, and each takes the outer `edgeWidth`.
    public static func hitZone(in rect: CGRect, at point: CGPoint, edgeWidth: CGFloat, minimumWidthForEdges: CGFloat) -> NoteHitZone? {
        guard rect.contains(point) else { return nil }
        guard rect.width >= minimumWidthForEdges else { return .body }

        if point.x < rect.minX + edgeWidth { return .startEdge }
        if point.x > rect.maxX - edgeWidth { return .endEdge }

        return .body
    }

    /// Under ⇧: the axis with the larger movement is the one that stays free.
    public static func axisLock(deltaX: Double, deltaY: Double) -> AxisLock {
        abs(deltaX) >= abs(deltaY) ? .timeOnly : .pitchOnly
    }

    /// The anchor note's start is snapped and the same delta applied to every note in the drag.
    public static func resolveMove(deltaSeconds: Double, deltaSemitones: Int, anchorStart: Double, grid: TempoGrid?, axisLock: AxisLock?) -> (seconds: Double, semitones: Int) {
        var seconds = deltaSeconds
        var semitones = deltaSemitones

        if let grid {
            seconds = grid.snap(anchorStart + deltaSeconds) - anchorStart
        }

        switch axisLock {
        case .timeOnly: semitones = 0
        case .pitchOnly: seconds = 0
        case nil: break
        }

        return (seconds, semitones)
    }

    /// The dragged edge of the anchor note is snapped; the same delta goes to every note.
    public static func resolveResize(deltaSeconds: Double, anchorEdgeTime: Double, grid: TempoGrid?) -> Double {
        guard let grid else { return deltaSeconds }

        return grid.snap(anchorEdgeTime + deltaSeconds) - anchorEdgeTime
    }

    /// The Draw tool's note: from the line at or before the click (or the click itself with snap
    /// off) to the pointer, never shorter than one division.
    public static func drawnNote(anchor: Double, current: Double, grid: TempoGrid, snapEnabled: Bool) -> (start: Double, end: Double) {
        let start = max(0, snapEnabled ? grid.snapDown(anchor) : anchor)
        let end = max(snapEnabled ? grid.snap(current) : current, start + grid.step)

        return (start, end)
    }

    /// Every note whose rect intersects the marquee (which may have negative extents).
    public static func marqueeSelection(_ rect: CGRect, notes: [(id: NoteID, rect: CGRect)]) -> Set<NoteID> {
        let marquee = rect.standardized

        return Set(notes.filter { $0.rect.intersects(marquee) }.map(\.id))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter EditGestureMath`
Expected: 5 pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: EditGestureMath, the roll editor's pure decisions"
```

---

### Task 5: `Workspace` and the session's transcription block (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/Workspace.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/SessionState.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/SessionStateTests.swift`

**Interfaces:**
- Produces: `enum Workspace: String, Codable, Sendable { case transcribe, edit }`; `SessionTranscription(sourceSampleCount:rawNotes:document:)`; on `SessionState`: `transcription: SessionTranscription?`, `workspace: Workspace`, `gridOffsetSeconds: Double`, `gridDivision: GridDivision`, `snapEnabled: Bool`, `targetProgram: Int?`.

- [ ] **Step 1: Write the failing tests** (append to `SessionStateTests.swift`)

```swift
@Test func sessionStateNewFieldsDefault() {
    let state = SessionState()
    #expect(state.transcription == nil)
    #expect(state.workspace == .transcribe)
    #expect(state.gridOffsetSeconds == 0)
    #expect(state.gridDivision == .sixteenth)
    #expect(state.snapEnabled)
    #expect(state.targetProgram == nil)
}

@Test func sessionStateRoundTripsATranscription() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")

    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0), NoteEvent(startTime: 1, endTime: 2, pitch: 38, program: 128)]
    var document = NoteDocument(events: raw)
    document.commit(document.delete([document.notes[0].id]))

    var state = SessionState()
    state.transcription = SessionTranscription(sourceSampleCount: 160_000, rawNotes: raw, document: document)
    state.workspace = .edit
    state.gridOffsetSeconds = 0.25
    state.gridDivision = .eighthTriplet
    state.snapEnabled = false
    state.targetProgram = 128

    try state.save(to: url)
    let loaded = SessionState.load(from: url)

    #expect(loaded.transcription?.sourceSampleCount == 160_000)
    #expect(loaded.transcription?.rawNotes == raw)
    #expect(loaded.transcription?.document.notes == document.notes)
    #expect(loaded.transcription?.document.isEdited == true)
    #expect(loaded.workspace == .edit)
    #expect(loaded.gridOffsetSeconds == 0.25)
    #expect(loaded.gridDivision == .eighthTriplet)
    #expect(!loaded.snapEnabled)
    #expect(loaded.targetProgram == 128)
}

@Test func sessionStateWithoutTheNewKeysStillLoads() throws {
    let directory = try makeSessionTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")
    try Data(#"{"exportTempo": 90, "zoomLevel": 2}"#.utf8).write(to: url)

    let loaded = SessionState.load(from: url)
    #expect(loaded.exportTempo == 90)
    #expect(loaded.zoomLevel == 2)
    #expect(loaded.transcription == nil)
    #expect(loaded.workspace == .transcribe)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter sessionState`
Expected: compile error on `transcription`.

- [ ] **Step 3: Implement**

`Workspace.swift`:

```swift
/// Which tab the window shows. In the core package because the session stores it.
public enum Workspace: String, Codable, Sendable {
    case transcribe, edit
}
```

In `SessionState.swift`, before `public struct SessionState`:

```swift
/// The transcription as the session keeps it: the model's own output, the edited document, and
/// the sample count of the audio it belongs to — a reloaded file of another length gets no notes.
public struct SessionTranscription: Codable, Equatable, Sendable {
    public var sourceSampleCount: Int
    public var rawNotes: [NoteEvent]
    public var document: NoteDocument

    public init(sourceSampleCount: Int, rawNotes: [NoteEvent], document: NoteDocument) {
        self.sourceSampleCount = sourceSampleCount
        self.rawNotes = rawNotes
        self.document = document
    }
}
```

Add the stored properties after `mixer`:

```swift
    /// The transcription, once there is a finished one; never while a run is in flight.
    public var transcription: SessionTranscription? = nil
    public var workspace: Workspace = .transcribe
    public var gridOffsetSeconds: Double = 0
    public var gridDivision: GridDivision = .sixteenth
    public var snapEnabled = true
    /// The instrument new and reassigned notes go to; nil means the first strip.
    public var targetProgram: Int? = nil
```

Extend `CodingKeys`:

```swift
        case zoomLevel, verticalZoom, selectedGroups, mixer
        case transcription, workspace, gridOffsetSeconds, gridDivision, snapEnabled, targetProgram
```

Append to `init(from:)`, after `mixer = …`:

```swift
        transcription = try container.decodeIfPresent(SessionTranscription.self, forKey: .transcription)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? defaults.workspace
        gridOffsetSeconds =
            try container.decodeIfPresent(Double.self, forKey: .gridOffsetSeconds) ?? defaults.gridOffsetSeconds
        gridDivision = try container.decodeIfPresent(GridDivision.self, forKey: .gridDivision) ?? defaults.gridDivision
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? defaults.snapEnabled
        targetProgram = try container.decodeIfPresent(Int.self, forKey: .targetProgram)
```

Update the doc comment's "the transcription is deliberately not part of this" sentence to: "The transcription is part of it once one has finished: the model's output and the edited document, guarded by the audio's sample count."

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: the session keeps the transcription, the workspace and the grid settings"
```

---

### Task 6: Velocity through the synth (audio)

**Files:**
- Modify: `app/NeuralSheet/Audio/NoteScheduler.swift` (`SynthEvent`, `collect`, `startNotesCovering`, `stopActive`)
- Modify: `app/NeuralSheet/Audio/InstrumentSynthBank.swift:80-81, 421`

**Interfaces:**
- Produces: `SynthEvent.velocity: UInt8`.

No core test covers the app target; the check is the build and a listen. Render-thread rule: the only additions are integer arithmetic on a `Double` already in the note buffer and one byte in a pre-sized struct.

- [ ] **Step 1: Add the byte to `SynthEvent`**

```swift
nonisolated struct SynthEvent: Equatable, Sendable {
    var sampleOffset: Int
    var program: Int
    var pitch: Int
    var isOn: Bool
    /// 1…127 for a note-on, 0 for a note-off.
    var velocity: UInt8
}
```

- [ ] **Step 2: Fill it in `NoteScheduler`**

Add to `NoteScheduler` (near `maxActiveNotes`):

```swift
    /// The note's amplitude as a MIDI velocity, 1…127. Integer arithmetic only: this runs on the
    /// render thread.
    static func velocity(forAmplitude amplitude: Double) -> UInt8 {
        let scaled = Int((amplitude * 127).rounded())

        return UInt8(clamping: Swift.min(Swift.max(scaled, 1), 127))
    }
```

Change the three `SynthEvent(...)` constructions:

- in `collect`'s onset loop: `SynthEvent(sampleOffset: offset, program: note.program, pitch: note.pitch, isOn: true, velocity: NoteScheduler.velocity(forAmplitude: note.amplitude))`
- in `startNotesCovering`: `SynthEvent(sampleOffset: 0, program: note.program, pitch: note.pitch, isOn: true, velocity: NoteScheduler.velocity(forAmplitude: note.amplitude))`
- in `stopActive`: `SynthEvent(sampleOffset: sampleOffset, program: note.program, pitch: note.pitch, isOn: false, velocity: 0)`

- [ ] **Step 3: Send it in `InstrumentSynthBank`**

Replace lines 80-81 (the `velocity` constant and its comment) with:

```swift
    // Velocity is per note now (`SynthEvent.velocity`); the design's fixed 100 is what every
    // model note still carries, so nothing sounds different until one is edited.
```

and line 421 with:

```swift
                bytes[2] = event.isOn ? event.velocity : 0
```

- [ ] **Step 4: Build**

Run: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v ThirdParty`
Expected: `** BUILD SUCCEEDED **`, no warnings in our files.

- [ ] **Step 5: Commit**

```bash
git add app/NeuralSheet/Audio
git commit -m "audio: the synth plays each note's amplitude as its velocity"
```

---
### Task 7: `AppModel` — workspace, document, editor commands, confirm, session, menus, keys

**Files:**
- Modify: `app/NeuralSheet/App/AppModel.swift` (state, `exportTempo`, `transition`, `clear`, `clearTranscription`, `resetTranscription`, `midiData`)
- Create: `app/NeuralSheet/App/AppModel+Editing.swift`
- Modify: `app/NeuralSheet/App/AppModel+Transcription.swift` (`launchTranscription`, `applyPostProcessing`, `handleFinished`)
- Modify: `app/NeuralSheet/App/AppModel+Session.swift` (`sessionSnapshot`, `restoreSession`)
- Modify: `app/NeuralSheet/App/Dialogs.swift` (confirm)
- Modify: `app/NeuralSheet/App/NeuralSheetApp.swift` (Edit menu, View menu)
- Modify: `app/NeuralSheet/App/KeyboardShortcuts.swift`
- Modify: `app/NeuralSheet/UI/Export/ExportDialog.swift` (range constants from `TempoGrid`)
- Modify: `app/NeuralSheet/UI/MainView.swift` (`Dialogs.installConfirm`)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces (the views' contract): `model.workspace`, `model.canEdit`, `model.setWorkspace(_:)`, `model.document: NoteDocument?`, `model.editor: EditorState` (`tool`, `selection`, `targetProgram`, `snapEnabled`, `grid`), `model.hasEdits`, `model.commit(_:)`, `model.undo()`, `model.redo()`, `model.canUndo`, `model.canRedo`, `model.undoMenuTitle`, `model.redoMenuTitle`, `model.revertToTranscription()`, `model.deleteSelection()`, `model.selectAll()`, `model.deselectAll()`, `model.setSelection(_:)`, `model.nudgeSelection(steps:semitones:)`, `model.quantizeSelectionOrAll()`, `model.setTool(_:)`, `model.setSnapEnabled(_:)`, `model.setGridDivision(_:)`, `model.setGridBpm(_:)`, `model.setGridOffset(_:)`, `model.setGridOffsetFromPlayhead()`, `model.setTargetProgram(_:)`, `model.escapePressed()`, `model.dragCanceller: (() -> Void)?`, `model.presentConfirm`.

- [ ] **Step 1: State on `AppModel`**

In `AppModel.swift`:

Under `// MARK: - State`, after `private(set) var state`:

```swift
    /// The tab on show (design §3.2). Only `setWorkspace` and `transition` write it.
    private(set) var workspace: Workspace = .transcribe
```

Replace `var exportTempo: Double = 120` (under `// MARK: - Export and settings`) with:

```swift
    /// The project tempo: the grid's BPM and the tempo the MIDI file is written at.
    var exportTempo: Double {
        get { editor.grid.bpm }
        set { editor.grid.bpm = TempoGrid.clampedBpm(newValue) }
    }
```

After the `transcription` property block (after `@ObservationIgnored var drainTimer: Timer?`):

```swift
    /// The editable transcription: nil until a run completes or a session restores one. Once it
    /// exists, `transcription.notes` is always `document.events` (`AppModel+Editing.swift`).
    var document: NoteDocument?

    /// The editor's tool, selection, target instrument, snap and grid.
    var editor = EditorState()
```

In `transition(to:)`, after `state = newState`:

```swift
        // The Edit tab is only for a finished transcription.
        if newState != .populated, workspace != .transcribe {
            workspace = .transcribe
        }
```

`clear()` and `clearTranscription()` become confirm-gated wrappers. Rename the bodies:

```swift
    /// Audio and transcription both (§2.6). Refused while a run is in flight: the drain owns the
    /// notes until the engine's completion lands, and cancelling is the way out of that. Edited
    /// notes are asked about first (design §3.5).
    func clear() {
        guard !jobActive else { return }

        confirmDiscardingEdits(action: "Clearing") { [weak self] in
            self?.clearNow()
        }
    }

    private func clearNow() {
        if state == .recording {
            // The take is discarded whatever came of it; the files go below.
            _ = recorder.stop()
        }

        resetTranscription()
        engine.setSource(nil)
        deleteRecordedFiles()

        source = nil
        duration = 0
        transition(to: .empty)
    }

    /// The transcription only, keeping the audio (§2.6).
    func clearTranscription() {
        guard !jobActive else { return }

        confirmDiscardingEdits(action: "Clearing") { [weak self] in
            self?.clearTranscriptionNow()
        }
    }

    func clearTranscriptionNow() {
        resetTranscription()
        transition(to: source != nil ? .audioLoaded : .empty)
    }
```

`launchTranscription` step 8 calls `clear()` for too-short audio: change it to `clearNow()` — make `clearNow` `func clearNow()` (internal, not private) since it lives in the same type across files. In `handleFinished` the `.cancelled` and failure branches call `clearTranscription()`: change both to `clearTranscriptionNow()` (a run that has just ended has no edits to protect).

In `resetTranscription()`, after `staging.reset()`:

```swift
        document = nil
        editor.selection = []
        dragCanceller?()
```

`midiData()`:

```swift
        return MidiFileWriter.data(
            notes: notes, bpm: exportTempo, startOffsetSeconds: editor.grid.offsetSeconds, mode: settings.midiOverflowMode)
```

Under `// MARK: - Dialogs`, after `presentError`:

```swift
    /// Installed by the view layer: `(title, body, confirm button title, completion)`. Nil
    /// confirms at once, which is what happens before a window exists.
    @ObservationIgnored var presentConfirm: ((String, String, String, @escaping (Bool) -> Void) -> Void)?

    /// Cancels the roll drag in progress, if the roll has one; installed by the edit controller.
    @ObservationIgnored var dragCanceller: (() -> Void)?
```

- [ ] **Step 2: `AppModel+Editing.swift`**

```swift
import Foundation
import NeuralSheetCore

/// The editor's own state, shared on the model because the AppKit roll and the SwiftUI inspector
/// both read it (design §5.3).
struct EditorState: Equatable {
    enum Tool: Equatable {
        case select, draw, erase
    }

    var tool: Tool = .select
    var selection: Set<NoteID> = []
    /// The instrument new and reassigned notes go to. Re-validated against the mixer's entries.
    var targetProgram: Int = 0
    var snapEnabled = true
    var grid = TempoGrid()

    /// A drawn or inserted note is one division long.
    var drawLength: Double { grid.step }
}

/// The document's place in the model and the commands the Edit tab calls (design §5).
extension AppModel {
    // MARK: - Workspace

    var canEdit: Bool { state == .populated && document != nil }

    func setWorkspace(_ workspace: Workspace) {
        guard workspace != self.workspace else { return }
        guard workspace == .transcribe || canEdit else { return }

        dragCanceller?()
        self.workspace = workspace
    }

    // MARK: - Document

    var hasEdits: Bool { document?.isEdited ?? false }

    /// Makes the document from the model's own output. The merge is the post-processing every
    /// raw note goes through; from here on the document's invariants replace it.
    func installDocument(rawNotes: [NoteEvent], document: NoteDocument? = nil) {
        transcription.rawNotes = rawNotes
        self.document = document ?? NoteDocument(events: mergeOverlappingNotesWithSamePitch(rawNotes))
        editor.selection = []
        applyDocument()
    }

    /// The only writer of `transcription.notes` once a document exists: the document's events go
    /// down the same path a decoded chunk did — synths first, then the mixer, then the scheduler.
    func applyDocument() {
        guard let document else { return }

        transcription.notes = document.events
        editor.selection = editor.selection.filter(document.contains)
        publishNotes()
        validateTargetProgram()
    }

    /// If the target instrument has left the mix, the first strip takes over.
    private func validateTargetProgram() {
        let programs = mixer.entries.map(\.program)

        if !programs.contains(editor.targetProgram), let first = programs.first {
            editor.targetProgram = first
        }
    }

    // MARK: - Commits and history

    func commit(_ batch: EditBatch) {
        guard var document, !batch.isEmpty else { return }

        document.commit(batch)
        self.document = document
        applyDocument()
    }

    var canUndo: Bool { document?.canUndo ?? false }
    var canRedo: Bool { document?.canRedo ?? false }
    var undoMenuTitle: String { document?.undoTitle.map { "Undo \($0)" } ?? "Undo" }
    var redoMenuTitle: String { document?.redoTitle.map { "Redo \($0)" } ?? "Redo" }

    func undo() {
        guard var document, document.canUndo else { return }

        dragCanceller?()
        document.undo()
        self.document = document
        applyDocument()
    }

    func redo() {
        guard var document, document.canRedo else { return }

        dragCanceller?()
        document.redo()
        self.document = document
        applyDocument()
    }

    /// Back to the model's own output, after asking (design §2).
    func revertToTranscription() {
        guard document != nil, hasEdits else { return }

        confirmDiscardingEdits(action: "Reverting to the transcription") { [weak self] in
            guard let self else { return }

            dragCanceller?()
            installDocument(rawNotes: transcription.rawNotes)
        }
    }

    /// Runs `proceed` at once when there is nothing to lose, otherwise after the user agrees.
    func confirmDiscardingEdits(action: String, proceed: @escaping () -> Void) {
        guard hasEdits, let presentConfirm else {
            proceed()
            return
        }

        presentConfirm("Discard your edits?",
                       "The transcription has been edited. \(action) will throw the edits away.",
                       "Discard") { confirmed in
            if confirmed {
                proceed()
            }
        }
    }

    // MARK: - Selection

    func setSelection(_ ids: Set<NoteID>) {
        guard let document else { return }

        let valid = ids.filter(document.contains)

        if valid != editor.selection {
            editor.selection = valid
        }
    }

    func selectAll() {
        guard let document else { return }

        editor.selection = Set(document.notes.map(\.id))
    }

    func deselectAll() {
        if !editor.selection.isEmpty {
            editor.selection = []
        }
    }

    func deleteSelection() {
        guard let document, !editor.selection.isEmpty else { return }

        commit(document.delete(editor.selection))
    }

    /// Arrow keys: `steps` grid divisions (or 10 ms each with snap off), `semitones` up.
    func nudgeSelection(steps: Int, semitones: Int) {
        guard let document, !editor.selection.isEmpty else { return }

        let seconds = Double(steps) * (editor.snapEnabled ? editor.grid.step : 0.010)

        commit(document.move(editor.selection, deltaSeconds: seconds, deltaSemitones: semitones))
    }

    /// Escape: a drag in progress is cancelled; otherwise the selection goes.
    func escapePressed() {
        if let dragCanceller {
            dragCanceller()
        } else {
            deselectAll()
        }
    }

    // MARK: - Tools and grid

    func setTool(_ tool: EditorState.Tool) {
        dragCanceller?()
        editor.tool = tool
    }

    func setSnapEnabled(_ enabled: Bool) {
        editor.snapEnabled = enabled
    }

    func setGridDivision(_ division: GridDivision) {
        editor.grid.division = division
    }

    func setGridBpm(_ bpm: Double) {
        editor.grid.bpm = TempoGrid.clampedBpm(bpm)
    }

    func setGridOffset(_ seconds: Double) {
        editor.grid.offsetSeconds = seconds.isFinite ? max(0, seconds) : 0
    }

    func setGridOffsetFromPlayhead() {
        setGridOffset(playheadSeconds)
    }

    func setTargetProgram(_ program: Int) {
        guard mixer.entries.contains(where: { $0.program == program }) else { return }

        editor.targetProgram = program
    }

    /// The selection, or everything when nothing is selected; starts only.
    func quantizeSelectionOrAll() {
        guard let document else { return }

        let ids = editor.selection.isEmpty ? Set(document.notes.map(\.id)) : editor.selection

        commit(document.quantize(ids, grid: editor.grid, lengths: false))
    }
}
```

- [ ] **Step 3: `AppModel+Transcription.swift`**

Split `applyPostProcessing` so the tail is shared:

```swift
    /// `_updatePostProcessing`: the raw notes become what is drawn, played and exported. While a
    /// run streams there is no document; the merge is the whole post-processing.
    private func applyPostProcessing() {
        transcription.notes = mergeOverlappingNotesWithSamePitch(transcription.rawNotes)
        publishNotes()
    }

    /// Order matters. The synths are created before the notes reach the scheduler, so no note can
    /// arrive at the bank for an instrument that has no player yet; the mixer is applied after
    /// they exist, so its faders land somewhere; and the gains are refreshed after the swap,
    /// because the mix is forced to source-only for as long as the scheduler has no notes (§5.3).
    func publishNotes() {
        for program in Set(notes.map(\.program)).sorted() {
            engine.synthBank.ensureInstrument(program: program)
        }

        refreshMixerEntries()

        engine.synthBank.scheduler.swap(notes: notes)
        engine.refreshGains()
    }
```

In `handleFinished`'s `.success` branch replace `transcription.rawNotes = final.map(NoteEvent.init(engineNote:))` … `applyPostProcessing()` with:

```swift
            transcription.finalizedThrough = duration
            transcription.progress = 1
            transcription.cancelLatched = false
            staging.reset()
            // The run's own result is authoritative, and it becomes the editable document.
            installDocument(rawNotes: final.map(NoteEvent.init(engineNote:)))
            transition(to: .populated)
```

In `launchTranscription`, step 1 becomes confirm-gated: rename the existing body to `private func launchTranscriptionNow()` (keeping steps 1–9 verbatim, with step 8's `clear()` → `clearNow()`), and add:

```swift
    /// The Transcribe button. A transcription that has been edited is asked about first (§3.5).
    func launchTranscription() {
        guard state == .audioLoaded else { return }

        confirmDiscardingEdits(action: "Transcribing again") { [weak self] in
            self?.launchTranscriptionNow()
        }
    }
```

(From `.audioLoaded` there is never a document, so this only ever confirms after a "clear transcription only" that was itself confirmed — the guard costs nothing and keeps the rule in one place.)

- [ ] **Step 4: Session (`AppModel+Session.swift`)**

In `sessionSnapshot()`, after `session.mixer = mixer.settings`:

```swift
        session.workspace = workspace
        session.gridOffsetSeconds = editor.grid.offsetSeconds
        session.gridDivision = editor.grid.division
        session.snapEnabled = editor.snapEnabled
        session.targetProgram = editor.targetProgram

        if state == .populated, let document, let source {
            session.transcription = SessionTranscription(sourceSampleCount: source.mono16k.count,
                                                         rawNotes: transcription.rawNotes,
                                                         document: document)
        }
```

In `restoreSession()`, replace the tail from `if !session.sourceAudioPath.isEmpty {` with:

```swift
        editor.grid.offsetSeconds = max(0, session.gridOffsetSeconds)
        editor.grid.division = session.gridDivision
        editor.snapEnabled = session.snapEnabled

        if !session.sourceAudioPath.isEmpty {
            restoreAudio(url: URL(fileURLWithPath: session.sourceAudioPath))
        }

        // The notes only with the very audio they were made from.
        if state == .audioLoaded, let saved = session.transcription, let source,
            source.mono16k.count == saved.sourceSampleCount
        {
            installDocument(rawNotes: saved.rawNotes, document: saved.document)
            transition(to: .populated)

            if let target = session.targetProgram {
                setTargetProgram(target)
            }

            setWorkspace(session.workspace)
        }

        if state.canPlay, session.playheadSeconds > 0 {
            seek(toSeconds: session.playheadSeconds)
        }
```

Update the extension's doc comment: "-- the take's path, the transport, the zoom, the selection, the mix and, once finished, the transcription --".

- [ ] **Step 5: `Dialogs.confirm`**

Add to `Dialogs`:

```swift
    /// Points `model.presentConfirm` at the window too.
    static func installConfirm(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentConfirm = { title, body, confirmTitle, completion in
            confirm(title: title, body: body, confirmTitle: confirmTitle, on: window(), completion: completion)
        }
    }

    /// A two-button question: the destructive choice first (so it reads as the action), Cancel as
    /// the default so Return is safe.
    static func confirm(title: String, body: String, confirmTitle: String, on window: NSWindow?,
                        completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning

        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            DispatchQueue.main.async {
                completion(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
```

In `MainView.appear()`, after `Dialogs.install(on: model) {…}`:

```swift
        Dialogs.installConfirm(on: model) { [windowController] in windowController.window }
```

- [ ] **Step 6: Menus (`NeuralSheetApp.swift`)**

Add `editMenu(model: model)` to `.commands { … }` after `fileMenu`, and:

```swift
    // MARK: - Edit menu

    /// Undo/Redo and the note commands, live in the Edit tab only. A text field that has the
    /// keyboard keeps its own undo, select-all and delete: the actions go down the responder
    /// chain in that case, as the system items would have.
    private func editMenu(model: AppModel) -> some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!Self.textFieldHasFocus && !(model.workspace == .edit && model.canUndo))

            Button(model.redoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!Self.textFieldHasFocus && !(model.workspace == .edit && model.canRedo))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Delete") { model.deleteSelection() }
                .disabled(model.workspace != .edit || model.editor.selection.isEmpty)

            Button("Select All") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else {
                    model.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Deselect All") { model.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.workspace != .edit)

            Divider()

            Button("Quantize") { model.quantizeSelectionOrAll() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.workspace != .edit)

            Button("Revert to Transcription…") { model.revertToTranscription() }
                .disabled(model.workspace != .edit || !model.hasEdits)
        }
    }

    /// Whether a text field is being typed in; the menu's shortcuts then belong to it.
    private static var textFieldHasFocus: Bool {
        let responder = NSApp.keyWindow?.firstResponder

        return responder is NSText || responder is NSTextField
    }
```

In `viewMenu`, before `Button("Reset Zoom")`:

```swift
            Button("Transcribe") { model.setWorkspace(.transcribe) }
                .keyboardShortcut("1", modifiers: .command)

            Button("Edit") { model.setWorkspace(.edit) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!model.canEdit)

            Divider()
```

- [ ] **Step 7: Keys (`KeyboardShortcuts.swift`)**

Add key codes:

```swift
    private enum KeyCode {
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        static let escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }
```

In `handle`, after the `guard !event.isARepeat` line insert the Edit-tab block (repeats are wanted for nudges, so place it *before* that guard, right after the `guard modifiers.isSubset(of: [.shift])` and `let shift` lines):

```swift
        if model.workspace == .edit, let handled = handleEditorKey(event, shift: shift) {
            return handled
        }
```

and add the method:

```swift
    /// The Edit tab's keys (design §5.4). Nil means the key is not the editor's.
    private func handleEditorKey(_ event: NSEvent, shift: Bool) -> Bool? {
        switch event.keyCode {
        case KeyCode.backspace where !shift, KeyCode.forwardDelete:
            model.deleteSelection()
            return true

        case KeyCode.escape:
            model.escapePressed()
            return true

        case KeyCode.left:
            model.nudgeSelection(steps: -1, semitones: 0)
            return true

        case KeyCode.right:
            model.nudgeSelection(steps: 1, semitones: 0)
            return true

        case KeyCode.up:
            model.nudgeSelection(steps: 0, semitones: shift ? 12 : 1)
            return true

        case KeyCode.down:
            model.nudgeSelection(steps: 0, semitones: shift ? -12 : -1)
            return true

        default:
            break
        }

        guard !shift, !event.isARepeat, let characters = event.charactersIgnoringModifiers else { return nil }

        switch characters.lowercased() {
        case "v":
            model.setTool(.select)
            return true
        case "d":
            model.setTool(.draw)
            return true
        case "e":
            model.setTool(.erase)
            return true
        case "r":
            // Recording is not possible from a finished transcription; swallowed rather than
            // reaching the record toggle.
            return true
        default:
            return nil
        }
    }
```

Update the class's doc table with the new rows (`⌫`/`⌦` delete selection, `←/→` nudge a grid step, `↑/↓` a semitone, `⇧↑/↓` an octave, `v/d/e` tools, `Esc` cancel drag or deselect — Edit tab only).

- [ ] **Step 8: `ExportDialog` constants**

Replace `static let minTempo = 20.0`, `maxTempo = 999.0`, `defaultTempo = 120.0` with `TempoGrid.minBpm`, `TempoGrid.maxBpm`, `TempoGrid.defaultBpm` and `tempo(from:)`'s body with `TempoGrid.clampedBpm(Double(text.trimmingCharacters(in: .whitespaces)) ?? .nan)`. Keep the footer text.

- [ ] **Step 9: Build and smoke**

Run the build command (Global Constraints). Expected: `** BUILD SUCCEEDED **`, no warnings in our files. Then, with the `run` skill: load a file, transcribe, quit, relaunch — the notes are back without transcribing again, and Edit is enabled in the View menu.

- [ ] **Step 10: Commit**

```bash
git add app/NeuralSheet/App app/NeuralSheet/UI/Export/ExportDialog.swift app/NeuralSheet/UI/MainView.swift
git commit -m "app: the editable document, the workspace, the editor commands and the session's transcription"
```

---
### Task 8: The tab strip and the per-workspace composition (ui)

**Files:**
- Create: `app/NeuralSheet/UI/TabStrip.swift`
- Modify: `app/NeuralSheet/UI/MainView.swift` (composition)

**Interfaces:**
- Consumes: `model.workspace`, `model.canEdit`, `model.setWorkspace(_:)`.
- Produces: `TabStrip(model:)`, `TabStrip.height = 32`. `MainView` shows `EditToolbar` (Task 10) in the Edit tab; until Task 10 lands, the Edit tab shows the same `Toolbar`.

- [ ] **Step 1: `TabStrip.swift`**

```swift
import NeuralSheetCore
import SwiftUI

/// The workspace tabs under the top bar (design §3.1): TRANSCRIBE, and EDIT once there is a
/// finished transcription. Room to the right for more.
struct TabStrip: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    static let height: CGFloat = 32
    private static let paddingLeft: CGFloat = 18
    private static let tabGap: CGFloat = 16
    private static let underlineHeight: CGFloat = 2

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: s(Self.tabGap)) {
            TabButton(title: "TRANSCRIBE",
                      isActive: model.workspace == .transcribe,
                      isEnabled: true,
                      tooltip: nil) { model.setWorkspace(.transcribe) }

            TabButton(title: "EDIT",
                      isActive: model.workspace == .edit,
                      isEnabled: model.canEdit,
                      tooltip: model.canEdit ? nil : "Transcribe the audio first") { model.setWorkspace(.edit) }

            Spacer(minLength: 0)
        }
        .padding(.leading, s(Self.paddingLeft))
        .frame(height: s(Self.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgTopBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divStrong)
                .frame(height: k)
        }
    }

    /// One tab: the label, and the accent underline flush with the strip's border when active.
    private struct TabButton: View {
        let title: String
        let isActive: Bool
        let isEnabled: Bool
        let tooltip: String?
        let action: () -> Void

        @Environment(\.uiScale) private var k
        @State private var isHovered = false

        var body: some View {
            let s = Scaled(k: k)
            let colour = isActive || (isHovered && isEnabled) ? Theme.textPrimary : Theme.textMuted

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(title)
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                            pointSize: Fonts.Size.sectionHeader,
                                            scale: k))
                    .foregroundStyle(colour)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(isActive ? Theme.accent : Color.clear)
                    .frame(height: s(TabStrip.underlineHeight))
            }
            .frame(height: s(TabStrip.height - 1))
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Theme.disabledAlpha)
            .onHover { isHovered = $0 }
            .onTapGesture { if isEnabled { action() } }
            .pointerStyle(isEnabled ? .link : nil)
            .tooltip(tooltip ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
        }
    }
}
```

(Check `TooltipModifier.tooltip(_:)`'s handling of an empty string; if it shows an empty popup, wrap with `if let tooltip` using `@ViewBuilder`.)

- [ ] **Step 2: `MainView.composition`**

```swift
    private var composition: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            TabStrip(model: model)

            HStack(spacing: 0) {
                Sidebar(model: model)

                VStack(spacing: 0) {
                    if model.workspace == .edit {
                        EditToolbar(model: model)
                    } else {
                        Toolbar(model: model)
                    }

                    TimelineView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if model.workspace == .transcribe, model.needsModelNotice {
                                NoModelNotice(model: model)
                                    .padding(.leading, TimelineMetrics.gutterWidth)
                                    .padding(.top, TimelineMetrics.pianoRollY)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if let notice = model.updateNotice {
                                UpdateNoticeView(model: model, notice: notice)
                            }
                        }

                    StatusBar(model: model)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
```

Until Task 10 exists, write `Toolbar(model: model)` in both branches so the build stays green; Task 10 replaces the Edit branch. Update the doc comment: "top bar over the tab strip over a full-height sidebar…".

- [ ] **Step 3: Build and look**

Build (Global Constraints). With the `run` skill: the strip shows under the top bar, EDIT dimmed with the tooltip until a transcription finishes, `⌘2` switches, clearing switches back.

- [ ] **Step 4: Commit**

```bash
git add app/NeuralSheet/UI/TabStrip.swift app/NeuralSheet/UI/MainView.swift
git commit -m "ui: a Transcribe / Edit tab strip under the top bar"
```

---

### Task 9: Timeline mode — waveform strip, ruler bars.beats and seek, roll grid and velocity (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Timeline/TimelineGeometry.swift` (`waveformHeight`, `waveformAmpHalfSpan`, `rollY`, `pitch(forY:)`)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView.swift` (`mode`, layout, overlays)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView+Model.swift` (observe `workspace`, `editor.grid`)
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView+Interaction.swift:93` (`overRoll`)
- Modify: `app/NeuralSheet/UI/Timeline/WaveformView.swift`, `RulerView.swift` (incl. `GutterView`), `PianoRollView.swift`

**Interfaces:**
- Consumes: `model.workspace`, `model.editor.grid`, `TempoGrid.lines`, `barBeatLabel`.
- Produces: `TimelineMode`, `TimelineContainerView.mode`, `TimelineGeometry.waveformHeight/rollY/waveformAmpHalfSpan/pitch(forY:)`, `RulerView.grid`, `RulerView.onSeek`, `PianoRollView.grid`, `GutterView.isCompact`.

- [ ] **Step 1: Geometry**

In `TimelineMetrics` add `static let waveformHeightEdit: CGFloat = 40` and `static let waveformAmpHalfSpanEdit: CGFloat = 14`. In `TimelineGeometry`, under `// MARK: - Time axis`:

```swift
    /// The waveform band's height in authored pixels: 126 in the Transcribe tab, 40 in Edit.
    var waveformHeight: CGFloat = TimelineMetrics.waveformHeight
    /// Where amplitude ±1.0 lands, measured from the band's centre.
    var waveformAmpHalfSpan: CGFloat = TimelineMetrics.waveformAmpHalfSpan
    /// Centre of the 1 px line drawn at `waveformHeight / 2`, so amplitude 0 lands mid-pixel.
    var waveformCentreY: CGFloat { waveformHeight * 0.5 + 0.5 }
    /// The roll's top, in authored pixels.
    var rollY: CGFloat { waveformHeight + TimelineMetrics.rulerHeight }
```

and under the pitch axis:

```swift
    /// The pitch whose lane contains `y` (real points), or nil off the lanes.
    func pitch(forY y: CGFloat) -> Int? {
        guard pitchRange.low <= pitchRange.high else { return nil }

        for pitch in pitchRange.low...pitchRange.high {
            let lane = lane(forPitch: pitch)

            if y >= lane.y, y < lane.y + lane.height {
                return pitch
            }
        }

        return nil
    }
```

Replace every `TimelineMetrics.waveformHeight`, `.pianoRollY`, `.waveformCentreY`, `.waveformAmpHalfSpan` in `WaveformView`, `RulerView` (`GutterView`), `TimelineContainerView` and `+Interaction` with the `geometry.` equivalents (`geometry.waveformHeight`, `geometry.rollY`, …). `MainView`'s `NoModelNotice` padding keeps the constant (Transcribe tab only). `GutterView` has no geometry: give it `var waveformHeight: CGFloat = TimelineMetrics.waveformHeight` and `var isCompact = false` (both `didSet { needsDisplay = true }`); when `isCompact`, skip the three amplitude labels.

- [ ] **Step 2: Container mode**

In `TimelineContainerView`:

```swift
enum TimelineMode: Equatable {
    case transcribe, edit
}
```

```swift
    /// Transcribe or Edit (design §3.4): the waveform's height, what the ruler labels, what the
    /// roll draws and whether it edits. Zoom, scroll and pitch range carry across.
    var mode: TimelineMode = .transcribe {
        didSet {
            guard mode != oldValue else { return }

            let editing = mode == .edit
            geometry.waveformHeight = editing ? TimelineMetrics.waveformHeightEdit : TimelineMetrics.waveformHeight
            geometry.waveformAmpHalfSpan = editing ? TimelineMetrics.waveformAmpHalfSpanEdit : TimelineMetrics.waveformAmpHalfSpan
            gutter.waveformHeight = geometry.waveformHeight
            gutter.isCompact = editing
            waveform.isCompact = editing
            ruler.grid = editing ? model.editor.grid : nil
            roll.grid = editing ? model.editor.grid : nil
            needsLayout = true
            layoutDocument()
            configureViews()
            placeOverlays()
            waveform.needsDisplay = true
            ruler.needsDisplay = true
            roll.needsDisplay = true
            roll.setFrontier(seconds: frontierSeconds)
            updatePlayhead()
        }
    }
```

In `init`, after `roll.onSeek = …`: `ruler.onSeek = { [weak self] seconds in self?.seek(toSeconds: seconds) }`.

In `placeOverlays()`: `ctaHost.isHidden = !(rollIsIdle && hasModel) || mode == .edit` and `loadHost.isHidden = state != .empty || mode == .edit`.

In `Snapshot` add `var workspace: Workspace = .transcribe` and `var grid = TempoGrid()`; in `observeModel()` read `_ = model.workspace` and `_ = model.editor.grid`; in `sync()` fill them and add:

```swift
        if first || new.workspace != old.workspace {
            mode = new.workspace == .edit ? .edit : .transcribe
        }

        if mode == .edit, first || new.grid != old.grid || new.workspace != old.workspace {
            ruler.grid = new.grid
            roll.grid = new.grid
            ruler.needsDisplay = true
            roll.needsDisplay = true
        }
```

- [ ] **Step 3: Waveform**

`WaveformView` gets `var isCompact = false` (`didSet { if changed { cornerLabel.isHidden = isCompact || …; needsDisplay = true } }`). In `draw`, the corner label is shown only when `hasAudio && !isCompact`; the drop zone is never drawn when compact. `drawBars` already reads `centreY`/`halfSpan` off the geometry after Step 1, so the strip scales itself.

- [ ] **Step 4: Ruler**

`RulerView` gets:

```swift
    /// Bars and beats instead of seconds, in the Edit tab; nil labels seconds.
    var grid: TempoGrid?

    /// The click is a seek; the container owns the model.
    var onSeek: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(geometry.seconds(forX: x))
    }
```

In `draw`, after `guard canPlay`: `if let grid { drawBarsAndBeats(ctx, grid: grid, in: dirtyRect); return }` and:

```swift
    /// Design §6.4: a bar tick full height with its number, a beat tick half height with
    /// `bar.beat`; labels thinned to every 2nd, 4th, 8th… bar until they clear the minimum gap.
    private func drawBarsAndBeats(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect) {
        let k = geometry.scale
        let height = bounds.height
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let font = TimelineFonts.meta(k)
        let labelInset = 6 * k
        let labelWidth = 40 * k
        let barPixels = grid.secondsPerBeat * Double(TempoGrid.beatsPerBar) * pixelsPerSecond
        let beatPixels = grid.secondsPerBeat * pixelsPerSecond

        guard barPixels > 0 else { return }

        var barsPerLabel = 1
        while Double(barsPerLabel) * barPixels < RulerTicks.minLabelGap { barsPerLabel *= 2 }
        let labelBeats = beatPixels >= RulerTicks.minLabelGap

        let from = geometry.seconds(forX: dirtyRect.minX - labelInset - labelWidth)
        let to = geometry.seconds(forX: dirtyRect.maxX)

        for line in grid.lines(from: max(0, from), to: to, division: .quarter) {
            let x = CGFloat((line.seconds * pixelsPerSecond).rounded()) * k

            guard x < bounds.width else { break }

            let position = grid.barBeat(at: line.seconds + 1e-6)

            switch line.kind {
            case .bar:
                ctx.fill(CGRect(x: x, y: 0, width: k, height: height), TimelinePalette.divStrong)

                if (position.bar - 1) % barsPerLabel == 0 {
                    TimelineText.draw("\(position.bar)", font: font, colour: TimelinePalette.textBright,
                                      in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                                      anchor: .centredLeft, context: ctx)
                }

            case .beat:
                ctx.fill(CGRect(x: x, y: height / 2, width: k, height: height / 2), TimelinePalette.divOctave)

                if labelBeats {
                    TimelineText.draw(grid.barBeatLabel(at: line.seconds + 1e-6), font: font, colour: TimelinePalette.textFaint,
                                      in: CGRect(x: x + labelInset, y: 0, width: labelWidth, height: height),
                                      anchor: .centredLeft, context: ctx)
                }

            case .division:
                break
            }
        }
    }
```

- [ ] **Step 5: Roll grid and velocity alpha**

`PianoRollView` gets `var grid: TempoGrid?` and, at the end of `drawLanes` (after the loop):

```swift
        if let grid {
            drawGrid(ctx, grid: grid, in: dirtyRect)
        }
```

```swift
    /// Design §6.5: bar, beat and division lines over the lanes; the finer kinds drop out as
    /// they crowd.
    private func drawGrid(_ ctx: CGContext, grid: TempoGrid, in dirtyRect: CGRect) {
        let k = geometry.scale
        let pixelsPerSecond = Double(geometry.pixelsPerSecond / k)
        let divisionPixels = grid.step * pixelsPerSecond
        let beatPixels = grid.secondsPerBeat * pixelsPerSecond
        let drawDivisions = divisionPixels >= 6
        let drawBeats = beatPixels >= 3
        let division: GridDivision = drawDivisions ? grid.division : .quarter

        for line in grid.lines(from: max(0, geometry.seconds(forX: dirtyRect.minX)),
                               to: geometry.seconds(forX: dirtyRect.maxX), division: division) {
            let colour: CGColor

            switch line.kind {
            case .bar: colour = TimelinePalette.divStrong
            case .beat where drawBeats: colour = TimelinePalette.divOctave
            case .division where drawDivisions: colour = TimelinePalette.gridDivision
            default: continue
            }

            let x = CGFloat((line.seconds * pixelsPerSecond).rounded()) * k
            ctx.fill(CGRect(x: x, y: dirtyRect.minY, width: k, height: dirtyRect.height), colour)
        }
    }
```

Add `static let gridDivision = cg(Theme.divSoft, alpha: 0.5)` to `TimelinePalette`. In `drawNotes`, replace `let alpha = audible[program] ? 1 : PianoRollView.mutedNoteAlpha` with:

```swift
            // Velocity 1…127 → 0.45…1, so an edited velocity shows (§6.5); muted wins.
            let velocityAlpha = 0.45 + 0.55 * CGFloat(note.velocity - 1) / 126
            let alpha = audible[program] ? velocityAlpha : PianoRollView.mutedNoteAlpha
```

- [ ] **Step 6: Build and look**

Build. With the `run` skill in the Edit tab: the waveform is a 40 px strip with no labels, the ruler reads `1`, `1.2`, `1.3`… and seeks on click, the roll shows the grid, the CTA is gone; back in Transcribe everything is as before and the zoom/scroll did not move.

- [ ] **Step 7: Commit**

```bash
git add app/NeuralSheet/UI/Timeline
git commit -m "ui: the timeline's Edit mode: waveform strip, bars.beats ruler, grid, velocity shading"
```

---
### Task 10: Edit toolbar, icons, number field (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Icons.swift` (seven shapes)
- Create: `app/NeuralSheet/UI/Controls/NumberField.swift`
- Create: `app/NeuralSheet/UI/Toolbar/EditToolbar.swift`
- Modify: `app/NeuralSheet/UI/Toolbar/Toolbar.swift` (make `dragButton` reusable), `app/NeuralSheet/UI/MainView.swift` (use `EditToolbar`)

**Interfaces:**
- Consumes: Task 7's commands, `GridDivision`, `TempoGrid`.
- Produces: `Icons.ArrowStroked`, `PencilStroked`, `EraserStroked`, `MagnetStroked`, `UndoStroked`, `RedoStroked`, `PlayheadTargetStroked`; `NumberField(value:range:decimals:width:onCommit:)`; `MidiDragButton(model:)` (extracted from `Toolbar`); `EditToolbar(model:)`.

- [ ] **Step 1: Icons** — add to `Icons`, each in the 16×16 square through `IconGeometry.fitted`, stroked (no fills):

```swift
    // MARK: - Editor

    nonisolated struct ArrowStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 4.0, y: 2.5))
            p.addLine(to: CGPoint(x: 4.0, y: 13.0))
            p.addLine(to: CGPoint(x: 7.0, y: 10.2))
            p.addLine(to: CGPoint(x: 9.2, y: 14.0))
            p.addLine(to: CGPoint(x: 11.0, y: 13.1))
            p.addLine(to: CGPoint(x: 8.9, y: 9.4))
            p.addLine(to: CGPoint(x: 12.5, y: 9.2))
            p.closeSubpath()

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct PencilStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 3.0, y: 13.0))
            p.addLine(to: CGPoint(x: 3.6, y: 10.2))
            p.addLine(to: CGPoint(x: 10.8, y: 3.0))
            p.addLine(to: CGPoint(x: 13.0, y: 5.2))
            p.addLine(to: CGPoint(x: 5.8, y: 12.4))
            p.closeSubpath()
            p.move(to: CGPoint(x: 9.2, y: 4.6))
            p.addLine(to: CGPoint(x: 11.4, y: 6.8))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct EraserStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 6.0, y: 13.0))
            p.addLine(to: CGPoint(x: 2.8, y: 9.8))
            p.addLine(to: CGPoint(x: 9.6, y: 3.0))
            p.addLine(to: CGPoint(x: 13.2, y: 6.6))
            p.addLine(to: CGPoint(x: 6.8, y: 13.0))
            p.closeSubpath()
            p.move(to: CGPoint(x: 5.6, y: 7.0))
            p.addLine(to: CGPoint(x: 9.2, y: 10.6))
            p.move(to: CGPoint(x: 7.5, y: 13.0))
            p.addLine(to: CGPoint(x: 13.5, y: 13.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct MagnetStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 4.0, y: 3.0))
            p.addLine(to: CGPoint(x: 4.0, y: 9.0))
            p.addArc(center: CGPoint(x: 8.0, y: 9.0), radius: 4.0, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: 12.0, y: 3.0))
            p.move(to: CGPoint(x: 2.5, y: 5.5))
            p.addLine(to: CGPoint(x: 5.5, y: 5.5))
            p.move(to: CGPoint(x: 10.5, y: 5.5))
            p.addLine(to: CGPoint(x: 13.5, y: 5.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct UndoStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 6.0, y: 3.5))
            p.addLine(to: CGPoint(x: 3.0, y: 6.5))
            p.addLine(to: CGPoint(x: 6.0, y: 9.5))
            p.move(to: CGPoint(x: 3.0, y: 6.5))
            p.addLine(to: CGPoint(x: 10.0, y: 6.5))
            p.addArc(center: CGPoint(x: 10.0, y: 9.5), radius: 3.0, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: 6.5, y: 12.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct RedoStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 10.0, y: 3.5))
            p.addLine(to: CGPoint(x: 13.0, y: 6.5))
            p.addLine(to: CGPoint(x: 10.0, y: 9.5))
            p.move(to: CGPoint(x: 13.0, y: 6.5))
            p.addLine(to: CGPoint(x: 6.0, y: 6.5))
            p.addArc(center: CGPoint(x: 6.0, y: 9.5), radius: 3.0, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: 9.5, y: 12.5))

            return IconGeometry.fitted(p, in: rect)
        }
    }

    nonisolated struct PlayheadTargetStroked: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 7.0, height: 7.0))
            p.move(to: CGPoint(x: 8.0, y: 1.5))
            p.addLine(to: CGPoint(x: 8.0, y: 4.5))
            p.move(to: CGPoint(x: 8.0, y: 11.5))
            p.addLine(to: CGPoint(x: 8.0, y: 14.5))
            p.move(to: CGPoint(x: 1.5, y: 8.0))
            p.addLine(to: CGPoint(x: 4.5, y: 8.0))
            p.move(to: CGPoint(x: 11.5, y: 8.0))
            p.addLine(to: CGPoint(x: 14.5, y: 8.0))

            return IconGeometry.fitted(p, in: rect)
        }
    }
```

- [ ] **Step 2: `NumberField.swift`**

```swift
import SwiftUI

/// A small numeric field in the timeline's mono face: commits on Return or focus loss, steps by
/// `step` on ↑/↓ (×10 with ⇧), and clamps into `range`. Shared by the Edit toolbar and the
/// selection inspector.
struct NumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    var step: Double = 1
    /// Authored width.
    var width: CGFloat = 52
    let onCommit: (Double) -> Void

    @Environment(\.uiScale) private var k
    @State private var text = ""
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 22
    static let corner: CGFloat = 4

    var body: some View {
        let s = Scaled(k: k)

        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.mono(10, weight: 500, scale: k))
            .foregroundStyle(Theme.textStrong)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .padding(.horizontal, s(6))
            .frame(width: s(width), height: s(Self.height))
            .background(RoundedRectangle(cornerRadius: s(Self.corner), style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: s(Self.corner), style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: k))
            .onAppear { text = Self.format(value, decimals: decimals) }
            .onChange(of: value) { _, new in
                if !isFocused { text = Self.format(new, decimals: decimals) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
            .onKeyPress(.upArrow) { nudge(by: step); return .handled }
            .onKeyPress(.downArrow) { nudge(by: -step); return .handled }
            .onKeyPress(.upArrow, phases: .down) { press in
                press.modifiers.contains(.shift) ? { nudge(by: step * 10); return .handled }() : .ignored
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                press.modifiers.contains(.shift) ? { nudge(by: -step * 10); return .handled }() : .ignored
            }
    }

    private func commit() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite else {
            text = Self.format(value, decimals: decimals)
            return
        }

        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        text = Self.format(clamped, decimals: decimals)

        if clamped != value {
            onCommit(clamped)
        }
    }

    private func nudge(by delta: Double) {
        let current = Double(text.trimmingCharacters(in: .whitespaces)) ?? value
        let next = min(max(current + delta, range.lowerBound), range.upperBound)
        text = Self.format(next, decimals: decimals)
        onCommit(next)
    }

    static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
```

(If the two `onKeyPress` overloads conflict at compile time, keep only the `phases: .down` pair and read the modifier inside.)

- [ ] **Step 3: Extract the drag button**

Move `Toolbar.dragButton(canExport:)` and its two `@State`s into a new `struct MidiDragButton: View { let model: AppModel … }` in `Toolbar.swift` (the body is the existing code with `model.canExport` read inside). `Toolbar` uses `MidiDragButton(model: model)` where it used `dragButton(canExport: canExport)`. Keep `Toolbar.Metrics` `enum` accessible (already internal).

- [ ] **Step 4: `EditToolbar.swift`**

```swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit tab's row above the timeline (design §6.1): tools, snap and division, tempo and
/// downbeat, Quantize, Undo/Redo, and the Drag MIDI out button the Transcribe row has.
struct EditToolbar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var divisionMenu = PopupMenuPresenter()
    @State private var divisionAnchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let editor = model.editor

        VStack(spacing: 0) {
            HStack(spacing: s(Metrics.groupGap)) {
                toolSwitcher(editor.tool)

                HStack(spacing: s(4)) {
                    iconButton(isOn: editor.snapEnabled, tooltip: "Snap to grid", action: { model.setSnapEnabled(!editor.snapEnabled) }) {
                        Icons.MagnetStroked()
                    }

                    labelButton(editor.grid.division.label, tooltip: "Grid division") {
                        showDivisionMenu()
                    }
                    .background(AnchorCatcher { divisionAnchor = $0 })
                }

                HStack(spacing: s(6)) {
                    pillLabel("TEMPO")
                    NumberField(value: editor.grid.bpm, range: TempoGrid.minBpm ... TempoGrid.maxBpm, decimals: 0, width: 46) {
                        model.setGridBpm($0)
                    }
                    .tooltip("Project tempo, also the export tempo")

                    pillLabel("BEAT 1 AT")
                    NumberField(value: editor.grid.offsetSeconds, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 62) {
                        model.setGridOffset($0)
                    }
                    .tooltip("Where bar 1 starts, in seconds")

                    iconButton(isOn: false, tooltip: "Set from playhead", action: model.setGridOffsetFromPlayhead) {
                        Icons.PlayheadTargetStroked()
                    }
                }

                labelButton("Quantize", tooltip: "Quantize selection (⌘U)", action: model.quantizeSelectionOrAll)

                Spacer(minLength: 0)

                HStack(spacing: s(4)) {
                    iconButton(isOn: false, isEnabled: model.canUndo, tooltip: model.undoMenuTitle, action: model.undo) {
                        Icons.UndoStroked()
                    }
                    iconButton(isOn: false, isEnabled: model.canRedo, tooltip: model.redoMenuTitle, action: model.redo) {
                        Icons.RedoStroked()
                    }
                }

                MidiDragButton(model: model)
            }
            .frame(height: s(Metrics.buttonHeight))
            .padding(.top, s(7))
            .padding(.bottom, s(8))
            .padding(.horizontal, s(Metrics.paddingSide))

            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
        .frame(height: s(Metrics.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgRoot)
    }

    // MARK: - Pieces

    private func toolSwitcher(_ tool: EditorState.Tool) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(2)) {
            iconButton(isOn: tool == .select, tooltip: "Select (V)", action: { model.setTool(.select) }) { Icons.ArrowStroked() }
            iconButton(isOn: tool == .draw, tooltip: "Draw (D)", action: { model.setTool(.draw) }) { Icons.PencilStroked() }
            iconButton(isOn: tool == .erase, tooltip: "Erase (E)", action: { model.setTool(.erase) }) { Icons.EraserStroked() }
        }
        .padding(s(2))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
    }

    private func iconButton<Icon: Shape>(isOn: Bool, isEnabled: Bool = true, tooltip: String, action: @escaping () -> Void,
                                         @ViewBuilder icon: () -> Icon) -> some View {
        let s = Scaled(k: k)
        let icon = icon()

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            icon.stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))
                .frame(width: s(Metrics.buttonHeight - 4), height: s(Metrics.buttonHeight - 4))
        }
        .tooltip(tooltip)
    }

    private func labelButton(_ title: String, tooltip: String, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.textBright,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Metrics.buttonPadX))
                .frame(height: s(Metrics.buttonHeight))
        }
        .tooltip(tooltip)
    }

    private func pillLabel(_ text: String) -> some View {
        TrackedLabel(string: text, em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                     font: Fonts.pillLabel(k), scale: k)
            .foregroundStyle(Theme.textLabel)
    }

    private func showDivisionMenu() {
        guard let anchor = divisionAnchor else { return }

        let menu = divisionMenu
        let model = model
        let titles = GridDivision.allCases.map(\.label)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(GridDivision.allCases, id: \.self) { division in
                MenuRow(title: division.label, isTicked: model.editor.grid.division == division) {
                    menu.dismiss()
                    model.setGridDivision(division)
                }
            }
        }
    }
}

/// Hands the caller the AppKit view under a SwiftUI control, to anchor a popup to it.
private struct AnchorCatcher: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

Check `MenuRow`'s initialiser (`MenuPanel.swift:91`) for the exact parameter names (`title:isTicked:isEnabled:action:`) and match them.

- [ ] **Step 5: `MainView`** — replace the Edit branch's `Toolbar(model: model)` with `EditToolbar(model: model)`.

- [ ] **Step 6: Build and look**

Build. With the `run` skill in the Edit tab: the tools switch (and `v`/`d`/`e` move the highlight), the division menu opens and ticks, tempo and offset fields commit and clamp, `⌖` copies the playhead, Quantize moves the notes onto the grid and Undo brings them back.

- [ ] **Step 7: Commit**

```bash
git add app/NeuralSheet/UI
git commit -m "ui: the Edit toolbar: tools, snap, division, tempo, downbeat, quantize, undo/redo"
```

---
### Task 11: Roll editing — ids, hit testing, selection, preview, and the Select tool (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Timeline/PianoRollView.swift` (ids, `interaction`, mouse forwarding, tracking area)
- Create: `app/NeuralSheet/UI/Timeline/PianoRollView+Editing.swift` (selection, preview, hit test, marquee view, drawing)
- Create: `app/NeuralSheet/UI/Timeline/Editing/RollEditController.swift`
- Create: `app/NeuralSheet/UI/Timeline/Editing/RollEditController+Drag.swift`
- Modify: `app/NeuralSheet/UI/Timeline/TimelineContainerView.swift` (install/uninstall the controller, `scrollPitch(bySemitones:)`), `+Model.swift` (ids into the roll, selection), `+Interaction.swift` (`tick` calls `autoScrollTick`)

**Interfaces:**
- Consumes: Task 3's builders, Task 4's math, Task 7's `model.editor`, `commit`, `setSelection`, `dragCanceller`.
- Produces: `RollHit { id, zone, note, index }`, `DragPreview`, `PianoRollView.setNotes(_: [EditableNote])`, `.selection`, `.setPreview(_:)`, `.hit(at:)`, `.noteRects(intersecting:)`, `.interaction`, `.marquee`; `RollEditController(model:roll:geometry:container:)` with `mouseDown/Dragged/Up(at:event:)`, `cursor(at:)`, `cancelDrag()`, `autoScrollTick() -> Bool`, `uninstall()`.

- [ ] **Step 1: Ids in `PianoRollView`**

Replace `private var notes: [NoteEvent] = []` with:

```swift
    private(set) var notes: [NoteEvent] = []
    /// `ids[i]` identifies `notes[i]`; placeholder ids while a run streams (nothing hit-tests them).
    private(set) var ids: [NoteID] = []
```

`setNotes` becomes:

```swift
    func setNotes(_ newNotes: [EditableNote]) {
        let placeable = newNotes.filter { $0.note.startTime.isFinite && $0.note.endTime.isFinite }
        notes = placeable.map(\.note)
        ids = placeable.map(\.id)
        rebuildBuckets()
        refreshPreviewIndices()
    }
```

(the bucket code moves into `private func rebuildBuckets()`; `refreshPreviewIndices` is Step 2's). Step 2's extension lives in another file, so loosen `buckets`, `audible` and `colours` from `private` to `private(set)` and `drawnEnd(of:)` from `private static` to `static`. In `TimelineContainerView+Model.sync()`: `roll.setNotes(model.document?.notes ?? notes.enumerated().map { EditableNote(id: NoteID($0.offset), note: $0.element) })`, and `lastNotes` comparison stays on `[NoteEvent]`.

Add to `PianoRollView`:

```swift
    /// The edit controller, in Edit mode; without one a click seeks.
    weak var interaction: RollEditController?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let interaction {
            interaction.mouseDown(at: point, event: event)
        } else {
            onSeek?(geometry.seconds(forX: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        interaction?.mouseDragged(at: convert(event.locationInWindow, from: nil), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        interaction?.mouseUp(at: convert(event.locationInWindow, from: nil), event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let interaction else { return }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let interaction else {
            super.cursorUpdate(with: event)
            return
        }

        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }
```

Replace the existing `mouseDown` (the seek) with the one above.

- [ ] **Step 2: `PianoRollView+Editing.swift`**

```swift
import AppKit
import NeuralSheetCore

/// What the pointer landed on.
struct RollHit: Equatable {
    var id: NoteID
    var zone: NoteHitZone
    var note: NoteEvent
    var index: Int
}

/// A drag in progress, as the roll draws it (design §6.5): the document is untouched until the
/// mouse goes up, so the roll shows the affected notes where they would land.
struct DragPreview: Equatable {
    enum Kind: Equatable {
        case transform(deltaSeconds: Double, deltaSemitones: Int, duplicating: Bool)
        case resize(edge: NoteEdge, deltaSeconds: Double)
        case erase
        case draw(NoteEvent)
    }

    var kind: Kind
    var ids: Set<NoteID>
}

/// The accent-outlined rubber band. Positioned, never repainted.
final class MarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TimelinePalette.marqueeFill
        layer?.borderColor = TimelinePalette.marqueeBorder
        layer?.borderWidth = scale
    }

    var scale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension PianoRollView {
    static let selectionOutlineWidth: CGFloat = 1.5

    // MARK: - Selection and preview

    /// Repaints the notes whose outline changes.
    func setSelection(_ new: Set<NoteID>) {
        guard new != selection else { return }

        selection = new
        setNeedsDisplay(visibleRect)
    }

    func setPreview(_ new: DragPreview?) {
        guard new != preview else { return }

        preview = new
        refreshPreviewIndices()
        setNeedsDisplay(visibleRect)
    }

    /// The indices of the notes the preview names, so they can be drawn wherever they land
    /// rather than only from the buckets of where they were.
    func refreshPreviewIndices() {
        guard let preview else {
            previewIndices = []
            return
        }

        previewIndices = ids.indices.filter { preview.ids.contains(ids[$0]) }
    }

    // MARK: - Geometry

    /// The rect a note is drawn in, or nil when its pitch is off the range.
    func noteRect(_ note: NoteEvent) -> CGRect? {
        let k = geometry.scale
        let range = geometry.pitchRange

        guard note.pitch >= range.low, note.pitch <= range.high else { return nil }

        let lane = geometry.lane(forPitch: note.pitch)

        guard lane.y >= 0, lane.height < bounds.height else { return nil }

        let x = geometry.x(forSeconds: note.startTime)
        let width = max(1 * k, geometry.x(forSeconds: PianoRollView.drawnEnd(of: note)) - x - 1 * k)

        return CGRect(x: x, y: lane.y, width: width, height: lane.height)
    }

    /// The topmost note under `point` and where on it.
    func hit(at point: CGPoint) -> RollHit? {
        guard !buckets.isEmpty else { return nil }

        let k = geometry.scale
        let second = Int(max(0, geometry.seconds(forX: point.x)))

        guard second < buckets.count else { return nil }

        // Last drawn is topmost: walk the bucket backwards.
        for index in buckets[second].reversed() {
            let note = notes[index]

            guard let rect = noteRect(note),
                let zone = EditGestureMath.hitZone(in: rect, at: point, edgeWidth: RollEditController.edgeWidth * k,
                                                   minimumWidthForEdges: RollEditController.minimumWidthForEdges * k)
            else { continue }

            return RollHit(id: ids[index], zone: zone, note: note, index: index)
        }

        return nil
    }

    /// Every note whose rect touches `rect`, for the marquee.
    func noteRects(intersecting rect: CGRect) -> [(id: NoteID, rect: CGRect)] {
        let area = rect.standardized

        guard !buckets.isEmpty else { return [] }

        let first = max(0, Int(geometry.seconds(forX: area.minX)))
        let last = min(buckets.count - 1, Int(geometry.seconds(forX: area.maxX)))

        guard first <= last else { return [] }

        var seen = Set<Int>()
        var result: [(id: NoteID, rect: CGRect)] = []

        for bucket in first...last {
            for index in buckets[bucket] where seen.insert(index).inserted {
                if let noteRect = noteRect(notes[index]), noteRect.intersects(area) {
                    result.append((ids[index], noteRect))
                }
            }
        }

        return result
    }

    // MARK: - Drawing

    /// The note a preview turns `note` into, or nil when the preview erases it.
    func previewed(_ note: NoteEvent, id: NoteID) -> NoteEvent? {
        guard let preview, preview.ids.contains(id) else { return note }

        switch preview.kind {
        case let .transform(deltaSeconds, deltaSemitones, _):
            var moved = note
            moved.startTime += deltaSeconds
            moved.endTime += deltaSeconds
            moved.pitch = min(max(moved.pitch + deltaSemitones, 0), 127)

            return moved

        case let .resize(edge, deltaSeconds):
            var resized = note

            switch edge {
            case .start:
                resized.startTime = min(max(resized.startTime + deltaSeconds, 0), resized.endTime - NoteDocument.minimumLength)
            case .end:
                resized.endTime = max(resized.endTime + deltaSeconds, resized.startTime + NoteDocument.minimumLength)
            }

            return resized

        case .erase:
            return nil

        case .draw:
            return note
        }
    }

    /// Whether a transform preview also keeps the original in place.
    var previewDuplicates: Bool {
        if case let .transform(_, _, duplicating)? = preview?.kind { return duplicating }

        return false
    }

    /// The Draw tool's note in progress, if any.
    var drawnPreview: NoteEvent? {
        if case let .draw(note)? = preview?.kind { return note }

        return nil
    }

    /// One note: its fill at its velocity, the onset marker, and the selection outline.
    func drawNote(_ note: NoteEvent, in rect: CGRect, selected: Bool, ctx: CGContext) {
        let k = geometry.scale
        let program = min(max(note.program, 0), NoteEvent.drumProgram)
        let velocityAlpha = 0.45 + 0.55 * CGFloat(note.velocity - 1) / 126
        let alpha = audible[program] ? velocityAlpha : PianoRollView.mutedNoteAlpha
        let edgeWidth = PianoRollView.onsetEdgeWidth * k

        ctx.setAlpha(alpha)
        ctx.fillRoundedRect(rect, corner: PianoRollView.noteCorner * k, colours[program])

        if rect.width > 2 * edgeWidth {
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: edgeWidth, height: rect.height), TimelinePalette.noteOnsetEdge)
        }

        ctx.setAlpha(1)

        if selected {
            let width = PianoRollView.selectionOutlineWidth * k
            ctx.setStrokeColor(TimelinePalette.textPrimary)
            ctx.setLineWidth(width)
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                               cornerWidth: PianoRollView.noteCorner * k, cornerHeight: PianoRollView.noteCorner * k, transform: nil))
            ctx.strokePath()
        }
    }
}
```

Add to `TimelinePalette`: `static let textPrimary = cg(Theme.textPrimary)`, `marqueeBorder = cg(Theme.accent)`, `marqueeFill = cg(Theme.accent, alpha: 0.12)`.

In `PianoRollView` add the stored properties (stored properties cannot live in an extension):

```swift
    /// Design §6.5: the selection's outline, a drag's preview, and the indices the preview names.
    private(set) var selection: Set<NoteID> = []
    private(set) var preview: DragPreview?
    var previewIndices: [Int] = []
    let marquee = MarqueeView(frame: .zero)
```

`init` adds `addSubview(marquee)` before `addSubview(playhead)`; `configure()` sets `marquee.scale = geometry.scale`.

Rewrite `drawNotes`'s per-note loop to use the helpers:

```swift
        let previewSet = Set(previewIndices)

        for index in indices where !previewSet.contains(index) {
            let note = notes[index]

            guard let rect = noteRect(note), rect.maxX >= dirtyRect.minX, rect.minX <= dirtyRect.maxX else { continue }

            drawNote(note, in: rect, selected: selection.contains(ids[index]), ctx: ctx)
        }

        // The preview's notes, wherever they land now.
        for index in previewIndices {
            let original = notes[index]

            if previewDuplicates, let rect = noteRect(original) {
                drawNote(original, in: rect, selected: false, ctx: ctx)
            }

            guard let shown = previewed(original, id: ids[index]), let rect = noteRect(shown) else { continue }

            drawNote(shown, in: rect, selected: true, ctx: ctx)
        }

        if let drawn = drawnPreview, let rect = noteRect(drawn) {
            drawNote(drawn, in: rect, selected: true, ctx: ctx)
        }
```

(The `drawnPreview` branch must also run when `notes` is empty: move the `guard !notes.isEmpty, !buckets.isEmpty` at the top of `drawNotes` to only guard the bucket walk.)

- [ ] **Step 3: `RollEditController.swift`**

```swift
import AppKit
import NeuralSheetCore

/// Turns the roll's mouse events into selection changes and `EditBatch`es (design §7). Installed
/// by the container in Edit mode; the roll forwards to it.
///
/// A drag never touches the document: the controller keeps a ``DragSession`` and pushes a
/// ``DragPreview`` to the roll, and the mouse-up commits one batch.
@MainActor final class RollEditController {
    unowned let model: AppModel
    unowned let roll: PianoRollView
    let geometry: TimelineGeometry
    weak var container: TimelineContainerView?

    /// Authored pixels.
    static let edgeWidth: CGFloat = 6
    static let minimumWidthForEdges: CGFloat = 14
    static let dragThreshold: CGFloat = 3
    static let autoScrollPixelsPerTick: CGFloat = 12
    static let autoScrollTicksPerKey = 4

    struct DragSession {
        enum Kind: Equatable {
            /// Mouse is down; the kind is decided once it has moved `dragThreshold`.
            case pending
            case move, duplicate
            case resize(NoteEdge)
            case marquee
            case draw
            case erase
        }

        var kind: Kind = .pending
        var anchorPoint: CGPoint
        var anchorPitch: Int
        var anchorHit: RollHit?
        var ids: Set<NoteID> = []
        var initialSelection: Set<NoteID> = []
        var additive = false
        /// The last resolved transform, committed on mouse-up.
        var resolvedSeconds = 0.0
        var resolvedSemitones = 0
        var drawn: NoteEvent?
        var erased: Set<NoteID> = []
    }

    private(set) var session: DragSession?
    /// The pointer's last position in window coordinates, for auto-scroll to re-feed.
    var lastWindowPoint: CGPoint = .zero
    var autoScrollTicks = 0

    init(model: AppModel, roll: PianoRollView, geometry: TimelineGeometry, container: TimelineContainerView) {
        self.model = model
        self.roll = roll
        self.geometry = geometry
        self.container = container
        roll.interaction = self
        roll.setSelection(model.editor.selection)
        model.dragCanceller = { [weak self] in self?.cancelDrag() }
    }

    func uninstall() {
        cancelDrag()
        roll.interaction = nil
        roll.setSelection([])
        model.dragCanceller = nil
    }

    // MARK: - Mouse

    func mouseDown(at point: CGPoint, event: NSEvent) {
        lastWindowPoint = event.locationInWindow
        let shift = event.modifierFlags.contains(.shift)
        let hit = roll.hit(at: point)
        var session = DragSession(anchorPoint: point, anchorPitch: geometry.pitch(forY: point.y) ?? hit?.note.pitch ?? 60)
        session.anchorHit = hit
        session.additive = shift
        session.initialSelection = model.editor.selection

        switch model.editor.tool {
        case .select, .draw:
            if let hit {
                if shift {
                    var selection = model.editor.selection
                    if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                    model.setSelection(selection)
                } else if !model.editor.selection.contains(hit.id) {
                    model.setSelection([hit.id])
                }

                session.ids = model.editor.selection
            } else if model.editor.tool == .select {
                if !shift { model.deselectAll() }
                if event.clickCount == 2 { insertNote(at: point); return }
            } else {
                // Draw on empty: the note starts now and follows the drag.
                session.kind = .draw
                session.drawn = drawnNote(anchor: point, current: point)
                roll.setPreview(DragPreview(kind: .draw(session.drawn!), ids: []))
            }

        case .erase:
            if let hit {
                session.kind = .erase
                session.erased = [hit.id]
                roll.setPreview(DragPreview(kind: .erase, ids: session.erased))
            }
        }

        self.session = session
        container?.resumeDisplayLink()
    }

    func mouseDragged(at point: CGPoint, event: NSEvent) {
        lastWindowPoint = event.locationInWindow
        update(at: point, modifiers: event.modifierFlags)
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        guard self.session != nil else { return }

        // `update` may drop the session (a press that turned into nothing); read it after.
        update(at: point, modifiers: event.modifierFlags)

        guard let session = self.session else { return }

        self.session = nil
        roll.marquee.isHidden = true
        roll.setPreview(nil)

        guard let document = model.document else { return }

        switch session.kind {
        case .pending, .marquee:
            break

        case .move:
            guard session.resolvedSeconds != 0 || session.resolvedSemitones != 0 else { break }
            model.commit(document.move(session.ids, deltaSeconds: session.resolvedSeconds, deltaSemitones: session.resolvedSemitones))

        case .duplicate:
            var copy = document
            let batch = copy.duplicate(session.ids, deltaSeconds: session.resolvedSeconds, deltaSemitones: session.resolvedSemitones)
            model.replaceDocumentAndCommit(copy, batch)
            model.setSelection(Set(batch.inserted.map(\.id)))

        case let .resize(edge):
            guard session.resolvedSeconds != 0 else { break }
            model.commit(document.resize(session.ids, edge: edge, deltaSeconds: session.resolvedSeconds))

        case .draw:
            if let drawn = session.drawn {
                var copy = document
                let batch = copy.insert(drawn)
                model.replaceDocumentAndCommit(copy, batch)
                model.setSelection(Set(batch.inserted.map(\.id)))
            }

        case .erase:
            model.commit(document.delete(session.erased))
        }
    }

    /// Escape, a tool change, an undo: the preview goes and nothing is committed.
    func cancelDrag() {
        guard session != nil else { return }

        session = nil
        roll.marquee.isHidden = true
        roll.setPreview(nil)
    }

    // MARK: - Cursor

    func cursor(at point: CGPoint) -> NSCursor {
        switch model.editor.tool {
        case .draw:
            return .crosshair
        case .erase:
            return RollEditController.eraserCursor
        case .select:
            if let hit = roll.hit(at: point), hit.zone != .body {
                return .resizeLeftRight
            }

            return .arrow
        }
    }

    /// A 16 px eraser drawn from the toolbar's icon, hot spot at its tip.
    static let eraserCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            let path = Icons.EraserStroked().path(in: rect).cgPath
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(Icons.strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 13))
    }()

    // MARK: - Helpers

    /// Double-click on empty in Select, or a click in Draw: one division at the target program.
    func insertNote(at point: CGPoint) {
        guard var document = model.document, let pitch = geometry.pitch(forY: point.y) else { return }

        let span = drawnNote(anchor: point, current: point)
        let batch = document.insert(NoteEvent(startTime: span.startTime, endTime: span.endTime, pitch: pitch, program: model.editor.targetProgram))
        model.replaceDocumentAndCommit(document, batch)
        model.setSelection(Set(batch.inserted.map(\.id)))
    }

    func drawnNote(anchor: CGPoint, current: CGPoint) -> NoteEvent {
        let span = EditGestureMath.drawnNote(anchor: geometry.seconds(forX: anchor.x),
                                             current: geometry.seconds(forX: current.x),
                                             grid: model.editor.grid,
                                             snapEnabled: model.editor.snapEnabled)
        let pitch = geometry.pitch(forY: anchor.y) ?? 60

        return NoteEvent(startTime: span.start, endTime: span.end, pitch: pitch, program: model.editor.targetProgram)
    }
}
```

`insert` and `duplicate` are `mutating` (they take ids from the counter), so the controller works on a copy and hands both back; add to `AppModel+Editing.swift`:

```swift
    /// For the two builders that allocate ids: the copy they ran on becomes the document, then the
    /// batch is committed on it.
    func replaceDocumentAndCommit(_ document: NoteDocument, _ batch: EditBatch) {
        self.document = document
        commit(batch)
    }
```

- [ ] **Step 4: `RollEditController+Drag.swift`**

```swift
import AppKit
import NeuralSheetCore

/// The drag itself: deciding what a pending press became, resolving each move, and auto-scroll.
extension RollEditController {
    /// Every mouse move (and every auto-scroll tick) comes through here.
    func update(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session else { return }

        let k = geometry.scale
        let dx = point.x - session.anchorPoint.x
        let dy = point.y - session.anchorPoint.y

        if session.kind == .pending {
            guard hypot(dx, dy) >= RollEditController.dragThreshold * k else { return }

            switch (model.editor.tool, session.anchorHit?.zone) {
            case (_, .body?):
                session.kind = modifiers.contains(.option) ? .duplicate : .move
            case (_, .startEdge?):
                session.kind = .resize(.start)
            case (_, .endEdge?):
                session.kind = .resize(.end)
            case (.select, nil):
                session.kind = .marquee
            default:
                self.session = nil
                return
            }
        }

        let snap = model.editor.snapEnabled != modifiers.contains(.command) ? model.editor.grid : nil
        let deltaSeconds = geometry.seconds(forX: dx)

        switch session.kind {
        case .move, .duplicate:
            let pitch = geometry.pitch(forY: point.y) ?? session.anchorPitch
            let lock: AxisLock? = modifiers.contains(.shift) ? EditGestureMath.axisLock(deltaX: Double(dx), deltaY: Double(dy)) : nil
            let resolved = EditGestureMath.resolveMove(deltaSeconds: deltaSeconds,
                                                       deltaSemitones: pitch - session.anchorPitch,
                                                       anchorStart: session.anchorHit?.note.startTime ?? 0,
                                                       grid: snap, axisLock: lock)
            session.resolvedSeconds = resolved.seconds
            session.resolvedSemitones = resolved.semitones
            roll.setPreview(DragPreview(kind: .transform(deltaSeconds: resolved.seconds, deltaSemitones: resolved.semitones,
                                                         duplicating: session.kind == .duplicate),
                                        ids: session.ids))

        case let .resize(edge):
            let anchorEdge = edge == .start ? session.anchorHit?.note.startTime : session.anchorHit?.note.endTime
            session.resolvedSeconds = EditGestureMath.resolveResize(deltaSeconds: deltaSeconds, anchorEdgeTime: anchorEdge ?? 0, grid: snap)
            roll.setPreview(DragPreview(kind: .resize(edge: edge, deltaSeconds: session.resolvedSeconds), ids: session.ids))

        case .marquee:
            let rect = CGRect(x: session.anchorPoint.x, y: session.anchorPoint.y, width: dx, height: dy).standardized
            roll.marquee.frame = rect
            roll.marquee.isHidden = false
            let inside = EditGestureMath.marqueeSelection(rect, notes: roll.noteRects(intersecting: rect))
            model.setSelection(session.additive ? session.initialSelection.union(inside) : inside)

        case .draw:
            let drawn = drawnNote(anchor: session.anchorPoint, current: point)
            session.drawn = drawn
            roll.setPreview(DragPreview(kind: .draw(drawn), ids: []))

        case .erase:
            if let hit = roll.hit(at: point) {
                session.erased.insert(hit.id)
            }
            roll.setPreview(DragPreview(kind: .erase, ids: session.erased))

        case .pending:
            break
        }

        self.session = session
    }

    /// One display-link tick during a drag: scrolls when the pointer is past the viewport and
    /// re-feeds the drag at the same window point. True when it scrolled.
    func autoScrollTick() -> Bool {
        guard let session, session.kind != .pending, let container else { return false }

        let k = geometry.scale
        let visible = roll.visibleRect
        let point = roll.convert(lastWindowPoint, from: nil)
        var scrolled = false

        if point.x < visible.minX {
            container.scroll(toX: container.scrollView.contentView.bounds.minX - RollEditController.autoScrollPixelsPerTick * k)
            scrolled = true
        } else if point.x > visible.maxX {
            container.scroll(toX: container.scrollView.contentView.bounds.minX + RollEditController.autoScrollPixelsPerTick * k)
            scrolled = true
        }

        if point.y < visible.minY || point.y > visible.maxY {
            autoScrollTicks += 1

            if autoScrollTicks % RollEditController.autoScrollTicksPerKey == 0 {
                container.scrollPitch(bySemitones: point.y < visible.minY ? 1 : -1)
                scrolled = true
            }
        } else {
            autoScrollTicks = 0
        }

        if scrolled {
            // Every kind re-feeds, the marquee included: the pointer is still, the content moved.
            update(at: roll.convert(lastWindowPoint, from: nil), modifiers: NSEvent.modifierFlags)
        }

        return scrolled
    }
}
```

- [ ] **Step 5: Container wiring**

In `TimelineContainerView`: `var editController: RollEditController?`. In `mode`'s `didSet`, after the geometry changes:

```swift
            if editing {
                editController = RollEditController(model: model, roll: roll, geometry: geometry, container: self)
            } else {
                editController?.uninstall()
                editController = nil
            }
```

Add to the container (next to `scroll(toX:)` in `+Interaction`):

```swift
    /// Auto-scroll during a drag: one key up or down.
    func scrollPitch(bySemitones semitones: Int) {
        let before = Int(geometry.firstKey)
        geometry.firstKey += Double(semitones) * Double(geometry.keyWidth)
        geometry.settleFirstKey()

        if Int(geometry.firstKey) != before {
            keyboard.needsDisplay = true
            roll.needsDisplay = true
        }
    }
```

In `tick()`, before the idle accounting:

```swift
        let dragging = editController?.autoScrollTick() ?? false
```

and count `dragging` with `model.isPlaying || recording` so the link stays awake during a drag. In `+Model.sync()`, read `_ = model.editor.selection` in `observeModel` and, in `sync`, `roll.setSelection(model.editor.selection)` when in Edit mode (add `selection` to the snapshot to compare).

`deinit`/`viewDidMoveToWindow`: when the window goes away, `editController?.uninstall()`.

- [ ] **Step 6: Build and exercise**

Build. With the `run` skill in the Edit tab: click a note (outline), ⇧-click adds, marquee selects, drag moves with snap (⌘ frees it), ⇧ locks an axis, ⌥ duplicates, edges resize, `⌫` deletes, arrows nudge, dragging past the right edge scrolls, `Esc` cancels a drag, `⌘Z` restores every step. Playback keeps running under a drag.

- [ ] **Step 7: Commit**

```bash
git add app/NeuralSheet/UI/Timeline app/NeuralSheet/App/AppModel+Editing.swift
git commit -m "ui: roll editing: selection, drag previews, move, resize, duplicate, marquee"
```

---

### Task 12: Draw and Erase tools, double-click insert, cursors (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Timeline/Editing/RollEditController.swift`, `+Drag.swift` (already carry the Draw/Erase branches from Task 11 — this task verifies and finishes them)
- Modify: `app/NeuralSheet/UI/Timeline/PianoRollView.swift` (`resetCursorRects`)

Task 11 wrote the Draw and Erase code paths alongside Select; this task is their test cycle, since a reviewer can accept Select while rejecting Draw.

- [ ] **Step 1: Cursor rects**

In `PianoRollView`:

```swift
    override func resetCursorRects() {
        guard let interaction else { return }

        // The default for the whole roll; `mouseMoved` refines it over edges.
        addCursorRect(visibleRect, cursor: interaction.cursor(at: CGPoint(x: -1, y: -1)))
    }
```

and in `RollEditController.cancelDrag()` / `uninstall()` and `AppModel.setTool` paths make sure `roll.window?.invalidateCursorRects(for: roll)` runs: add `roll.window?.invalidateCursorRects(for: roll)` at the end of `cancelDrag()` and in the container's `sync()` when `editor.tool` changed (add `tool` to the snapshot, read `_ = model.editor.tool`).

- [ ] **Step 2: Exercise Draw**

With the `run` skill, `d`: the cursor is a crosshair; a click on empty adds a one-division note in the target instrument's colour, selected; a drag extends it to the pointer, snapped; a click on a note selects it and dragging it moves it (Draw behaves as Select on notes); the inserted note lands over an existing same-pitch note and trims it.

- [ ] **Step 3: Exercise Erase**

`e`: the eraser cursor; a click removes a note; a drag removes every note passed over, shown vanishing as the pointer crosses them; `⌘Z` brings them all back as one step ("Undo Delete Notes").

- [ ] **Step 4: Exercise double-click**

`v`: double-click on empty inserts as Draw's click does; a single click on empty only deselects.

- [ ] **Step 5: Fix what the exercise found, build, commit**

```bash
git add app/NeuralSheet/UI/Timeline
git commit -m "ui: Draw and Erase tools, double-click insert, editor cursors"
```

---
### Task 13: Target rail on the strips and the selection inspector (ui)

**Files:**
- Modify: `app/NeuralSheet/UI/Sidebar/InstrumentStrip.swift` (`isTarget`, `onChooseTarget`)
- Modify: `app/NeuralSheet/UI/Sidebar/Sidebar.swift` (`StripList` passes them in Edit mode; inspector above Master)
- Create: `app/NeuralSheet/UI/Sidebar/SelectionInspector.swift`

**Interfaces:**
- Consumes: `model.workspace`, `model.editor`, `model.document`, `model.setTargetProgram(_:)`, `model.commit(_:)`, the `setStart/setLength/setPitch/setProgram/setVelocity` builders, `NumberField`, `TimeFormat.pitchName`.
- Produces: `InstrumentStrip(model:entry:settings:level:width:isTarget:onChooseTarget:)`, `SelectionInspector(model:)`, `SelectionInspector.height = 150`.

- [ ] **Step 1: The strip's rail**

Add to `InstrumentStrip`:

```swift
    /// Edit tab: this strip's instrument is where new and reassigned notes go (design §6.2).
    var isTarget = false
    /// Edit tab: a click on the chip or the name makes this the target. Nil in the Transcribe tab.
    var onChooseTarget: (() -> Void)?
```

Wrap the identity row's chip-and-name `HStack` content (the `chip(…)` and the name `VStack`) in a group with `.contentShape(Rectangle()).onTapGesture { onChooseTarget?() }` (only when `onChooseTarget != nil`; use `.allowsHitTesting(onChooseTarget != nil)`). Add to the strip's modifiers, after `.background(settings.soloed ? … )`:

```swift
        .overlay(alignment: .leading) {
            if isTarget {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: s(2))
            }
        }
```

`InstrumentStrip` is `.equatable()` in the list: add `isTarget` to its `Equatable` conformance (the closure is excluded — write `static func ==` comparing `entry`, `settings`, `level`, `width`, `isTarget`, and `model === model`).

In `Sidebar.StripList`, pass:

```swift
                    InstrumentStrip(model: model,
                                    entry: entry,
                                    settings: model.mixer.settings[entry.program] ?? InstrumentChannelSettings(),
                                    level: model.instrumentLevelDb(program: entry.program),
                                    width: SidebarMetrics.stripWidth - scrollbarInset / k,
                                    isTarget: editing && model.editor.targetProgram == entry.program,
                                    onChooseTarget: editing ? { model.setTargetProgram(entry.program) } : nil)
```

with `let editing = model.workspace == .edit` above the `ForEach`.

- [ ] **Step 2: `SelectionInspector.swift`**

```swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// The sidebar's SELECTION panel in the Edit tab (design §6.3): what is selected, and five fields
/// that set it. Every commit is one batch over the whole selection.
struct SelectionInspector: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var instrumentMenu = PopupMenuPresenter()
    @State private var instrumentAnchor: NSView?

    static let height: CGFloat = 150
    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let rowHeight: CGFloat = 22
    private static let rowGap: CGFloat = 2

    /// The selected notes, in document order.
    private var selected: [NoteEvent] {
        guard let document = model.document else { return [] }

        let ids = model.editor.selection

        return document.notes.filter { ids.contains($0.id) }.map(\.note)
    }

    var body: some View {
        let s = Scaled(k: k)
        let notes = selected
        let enabled = !notes.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SELECTION")
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.textLabel)

                Spacer(minLength: 0)

                Text(countText(notes.count))
                    .font(Fonts.mono(10, weight: 400, scale: k))
                    .foregroundStyle(Theme.textFaintest)
            }
            .frame(height: s(Self.labelHeight))

            VStack(spacing: s(Self.rowGap)) {
                row("Instrument") { instrumentControl(notes: notes) }
                row("Start") {
                    NumberField(value: notes.first?.startTime ?? 0, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 72) { value in
                        commit { $0.setStart(model.editor.selection, seconds: value) }
                    }
                    .opacity(mixed(notes.map(\.startTime)) ? 0.5 : 1)
                }
                row("Length") {
                    NumberField(value: notes.first.map { $0.endTime - $0.startTime } ?? 0, range: NoteDocument.minimumLength ... 3_600,
                                decimals: 3, step: 0.01, width: 72) { value in
                        commit { $0.setLength(model.editor.selection, seconds: value) }
                    }
                    .opacity(mixed(notes.map { $0.endTime - $0.startTime }) ? 0.5 : 1)
                }
                row("Pitch") { pitchControl(notes: notes) }
                row("Velocity") {
                    HStack(spacing: s(6)) {
                        // A binding, as the strips' faders have it: every drag step is one small
                        // batch, each its own undo step.
                        PillSlider(value: Binding(get: { Double(notes.first?.velocity ?? 100) },
                                                  set: { value in commit { $0.setVelocity(model.editor.selection, velocity: Int(value)) } }),
                                   range: 1 ... 127, step: 1, width: s(60),
                                   fill: Theme.accent.opacity(0.85), track: Theme.faderTrack, thumb: Theme.faderThumb,
                                   onDoubleClick: { commit { $0.setVelocity(model.editor.selection, velocity: 100) } })

                        NumberField(value: Double(notes.first?.velocity ?? 100), range: 1 ... 127, decimals: 0, width: 40) { value in
                            commit { $0.setVelocity(model.editor.selection, velocity: Int(value)) }
                        }
                    }
                }
            }
            .padding(.top, s(8))
            .disabled(!enabled)
            .opacity(enabled ? 1 : Theme.disabledAlpha)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(SidebarMetrics.stripWidth), height: s(Self.height), alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }

    // MARK: - Rows

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(Self.rowHeight))
    }

    private func countText(_ count: Int) -> String {
        switch count {
        case 0: "No selection"
        case 1: "1 note"
        default: "\(count) notes"
        }
    }

    private func mixed<T: Equatable>(_ values: [T]) -> Bool {
        guard let first = values.first else { return false }

        return values.contains { $0 != first }
    }

    /// One batch on the document, through the model.
    private func commit(_ build: (NoteDocument) -> EditBatch) {
        guard let document = model.document else { return }

        model.commit(build(document))
    }

    // MARK: - Instrument

    private func instrumentControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let programs = notes.map(\.program)
        let title = programs.isEmpty || mixed(programs) ? "—" : Instruments.info(forProgram: programs[0]).name

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: showInstrumentMenu) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .lineLimit(1)
                .frame(width: s(120), height: s(NumberField.height), alignment: .leading)
                .padding(.horizontal, s(6))
        }
        .background(AnchorCatcher { instrumentAnchor = $0 })
    }

    private func showInstrumentMenu() {
        guard let anchor = instrumentAnchor else { return }

        let menu = instrumentMenu
        let model = model
        let current = Set(selected.map(\.program))
        let titles = Instruments.all.map(\.name)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(Instruments.all, id: \.program) { info in
                MenuRow(title: info.name, isTicked: current == [info.program]) {
                    menu.dismiss()
                    commit { $0.setProgram(model.editor.selection, program: info.program) }
                }
            }
        }
    }

    // MARK: - Pitch

    private func pitchControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let pitches = notes.map(\.pitch)

        return PitchField(text: pitches.isEmpty || mixed(pitches) ? "—" : TimeFormat.pitchName(pitches[0]), width: s(72), scale: k) { pitch in
            commit { $0.setPitch(model.editor.selection, pitch: pitch) }
        }
    }
}

/// A note-name field: accepts `C#4`, `Db4` or a MIDI number.
private struct PitchField: View {
    let text: String
    let width: CGFloat
    let scale: CGFloat
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(Fonts.mono(10, weight: 500, scale: scale))
            .foregroundStyle(Theme.textStrong)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .padding(.horizontal, 6 * scale)
            .frame(width: width, height: NumberField.height * scale)
            .background(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: scale))
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let pitch = PitchField.parse(draft) {
            onCommit(pitch)
        } else {
            draft = text
        }
    }

    /// `C4`, `C#4`, `Db-1`, or `60`.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()

        if let number = Int(trimmed) { return (0...127).contains(number) ? number : nil }

        let names: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

        guard let letter = trimmed.first, var pitchClass = names[letter] else { return nil }

        var rest = trimmed.dropFirst()

        if rest.first == "#" { pitchClass += 1; rest = rest.dropFirst() }
        else if rest.first == "B", rest.count > 1 { pitchClass -= 1; rest = rest.dropFirst() }

        guard let octave = Int(rest) else { return nil }

        let midi = (octave + 1) * 12 + pitchClass

        return (0...127).contains(midi) ? midi : nil
    }
}
```

- [ ] **Step 3: Shared `AnchorCatcher`**

Move `AnchorCatcher` from `EditToolbar.swift` into `Controls/NumberField.swift` (drop `private`), since the inspector's instrument popup anchors the same way.

- [ ] **Step 4: Sidebar composition**

In `Sidebar.body`, between the `ScrollView` and `MasterPanel`:

```swift
            if model.workspace == .edit {
                SelectionInspector(model: model)
            }
```

- [ ] **Step 5: Build and exercise**

Build. With the `run` skill in the Edit tab: click a strip's name → the rail moves and a drawn note takes that colour; select notes → the panel counts them; Instrument popup reassigns and a new strip appears; Start/Length/Pitch/Velocity commit on Return and undo as one step each; mixed values show "—".

- [ ] **Step 6: Commit**

```bash
git add app/NeuralSheet/UI
git commit -m "ui: target instrument rail and the selection inspector"
```

---

### Task 14: Docs — departures, README, changelog

**Files:**
- Modify: `AGENTS.md:45` (departures list), `README.md` (usage), `CHANGELOG.md`

- [ ] **Step 1: `AGENTS.md`**

Extend the "Deliberate departures so far" sentence with: "; a Transcribe / Edit tab strip under the top bar, and in the Edit tab a 40 px waveform, a bars-and-beats ruler that seeks on click, editing tools in the toolbar and sidebar, and a roll whose click selects rather than seeks; the synth plays per-note velocity (the model's notes still carry 100); the export tempo is the project tempo on the Edit toolbar; the session stores the transcription. Design: `docs/design/2026-09-19-midi-editor-design.md`."

Add under "Where things are": `UI/Timeline/Editing/  The roll's edit controller` and `docs/design/` line: "…, the MIDI editor design and plan".

Add a rule under "Rules that are not negotiable": "**Edits go through `NoteDocument`.** Every change to the notes after a transcription finishes is an `EditBatch` committed through `AppModel.commit`; nothing writes `transcription.notes` directly once a document exists."

- [ ] **Step 2: `README.md`**

In "What it does", after "Listen and mix": "- **Edit the notes.** Switch to the Edit tab: move, resize, draw and erase notes, reassign them to other instruments, set velocities, snap and quantize to a tempo grid, with undo. Edits are saved with the session." In "Usage", add step "5. **Edit.** `⌘2` opens the Edit tab. `V` selects, `D` draws, `E` erases; drag notes, or their ends; `⌥`-drag duplicates; arrows nudge. Set the tempo and where bar 1 falls in the toolbar." and renumber Export to 6. Shortcuts line: add "`⌘1`/`⌘2` tabs · `⌘Z` undo · `⌘U` quantize".

- [ ] **Step 3: `CHANGELOG.md`**

Under an "Unreleased" heading: "Added: an Edit tab with full MIDI editing on the piano roll (select, move, resize, draw, erase, duplicate, reassign instrument, velocity, snap and quantize to a tempo grid, undo/redo, revert to transcription); the transcription is saved in the session. Changed: the synth plays per-note velocity; the export tempo is set on the Edit toolbar."

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md README.md CHANGELOG.md
git commit -m "docs: the MIDI editor in the agent guide, the README and the changelog"
```

---

## Notes for the executor

- Task order is the dependency order; 1–5 can be done in parallel (separate files), 6 is independent of 1–5, 7 needs 1–5, 8–13 need 7 and each other in order, 14 last.
- Every task ends with `swift test` (1–5) or the warning-free build (6–13). Never claim a UI task done without the `run`-skill exercise in its last step.
- The spec's §7.2 auto-scroll and §7.3 tool table are the acceptance list for Tasks 11–12; §6.3's table for Task 13.
