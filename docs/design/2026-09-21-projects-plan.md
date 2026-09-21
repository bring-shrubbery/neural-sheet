# Projects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Library autosave session with `.neuralsheet` project packages, the standard Mac save lifecycle around them, and an Xcode-style welcome window.

**Architecture:** The file format (`ProjectState`, `ProjectTranscription`, `ProjectContent`, `ProjectPackage`) lives in NeuralSheetCore behind `swift test`. `AppModel+Project.swift` owns the lifecycle (new, open, save, save as, revert, close, review) on the single `AppModel`; a `ProjectTracker` computes the edited flag from a content snapshot; the main window shows title, proxy icon and dirty dot and vetoes its close through a delegate proxy; the app delegate handles quit and Finder opens; a second SwiftUI `Window` scene is the welcome window.

**Tech Stack:** Swift 6 language mode in the app (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift 5 mode in the core package tests, SwiftUI scenes + AppKit (`NSSavePanel`, `NSOpenPanel`, `NSAlert`, `NSWindowDelegate`, `NSDocumentController` recents), Swift Testing (`@Test`, `#expect`, `#require`).

**Spec:** `docs/design/2026-09-21-projects-design.md`

## Global Constraints

- Build: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20` must be warning-free in our files.
- Tests: `cd app/Packages/NeuralSheetCore && swift test` must pass.
- Commit as you go: one commit per task, message `area: what` in lowercase (`core:`, `app:`, `ui:`, `docs:`), body says why when not obvious, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Never edit `project.pbxproj` for source files; new Swift files are picked up automatically. `app/Info.plist` is merged with the generated plist.
- Views use the `AppModel` public contract only; never call `transition(to:)` or touch `transcription`, `engine`, `synthBank`, `recorder` from a view.
- Split any file approaching 400 lines with the `+Extension.swift` pattern.
- User-facing strings say "NeuralSheet"; the document sheets use AppKit's exact wording (spec §7).
- Package extension `neuralsheet`; type identifier `com.quassum.neuralsheet.project`; layout `project.json`, `transcription.json`, `audio/<file>`; a recording is `audio/recording.wav`.
- Dirty rule is content only: audio identity, transcription, mixer, selected groups, tempo, grid offset and division, snap, target program. Tab, playhead, follow, zoom, note selection never dirty.
- The MIDI overflow mode stays in `GlobalSettings` and is not in the project file.

---

### Task 1: `ProjectState` replaces `SessionState` (core)

**Files:**
- Rename: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/SessionState.swift` → `ProjectState.swift`
- Rename: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/SessionStateTests.swift` → `ProjectStateTests.swift`

**Interfaces:**
- Produces: `public struct ProjectState: Codable, Equatable, Sendable` with the fields below, `ProjectState.currentFormatVersion`, `static func read(from: URL) throws -> ProjectState`, `func save(to: URL) throws`, `static func parseSelectedGroups(_:) -> [Int32]`; `public enum ProjectError: Error, Equatable { case notAPackage, unreadable(String), newerVersion(Int), missingAudio, couldNotWrite(String) }`; `public enum Workspace` unchanged.
- The `SessionTranscription` type stays in this file until Task 2 renames it (the old `transcription` field is removed here, so nothing in this file references it after the edit).

- [ ] **Step 1: Rename the files with git**

```bash
cd app/Packages/NeuralSheetCore
git mv Sources/NeuralSheetCore/SessionState.swift Sources/NeuralSheetCore/ProjectState.swift
git mv Tests/NeuralSheetCoreTests/SessionStateTests.swift Tests/NeuralSheetCoreTests/ProjectStateTests.swift
```

- [ ] **Step 2: Rewrite the tests for `ProjectState`**

Replace the whole of `ProjectStateTests.swift` with:

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

/// A fresh directory under the system temp area. Never the user's real Library.
private func makeProjectTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func projectStateDefaultsMatchTheApp() {
    let state = ProjectState()

    #expect(state.formatVersion == ProjectState.currentFormatVersion)
    #expect(state.audioFileName == "")
    #expect(state.audioDisplayName == nil)
    #expect(state.selectedGroups.isEmpty)
    #expect(state.mixer.isEmpty)
    #expect(state.exportTempo == 120)
    #expect(state.gridOffsetSeconds == 0)
    #expect(state.gridDivision == .sixteenth)
    #expect(state.snapEnabled)
    #expect(state.targetProgram == nil)
    #expect(state.workspace == .transcribe)
    #expect(state.playheadSeconds == 0)
    #expect(state.playheadCentered)
    #expect(state.zoomLevel == 1)
    #expect(state.verticalZoom == -1)
}

@Test func projectStateRoundTripsThroughAFile() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")

    var state = ProjectState()
    state.audioFileName = "take.flac"
    state.audioDisplayName = "take"
    state.selectedGroups = [0, 36]
    state.mixer = [
        0: InstrumentChannelSettings(gainDb: -6, muted: true, soloed: false),
        33: InstrumentChannelSettings(gainDb: 1.5, muted: false, soloed: true),
    ]
    state.exportTempo = 96.5
    state.gridOffsetSeconds = 0.25
    state.gridDivision = .eighthTriplet
    state.snapEnabled = false
    state.targetProgram = 128
    state.workspace = .edit
    state.playheadSeconds = 12.25
    state.playheadCentered = false
    state.zoomLevel = 3.5
    state.verticalZoom = 2

    try state.save(to: url)

    #expect(try ProjectState.read(from: url) == state)
}

@Test func projectStateMissingFileIsUnreadable() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("no-such-project.json")

    #expect(throws: ProjectError.self) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateCorruptFileIsUnreadable() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try Data("{ this is not json".utf8).write(to: url)

    #expect(throws: ProjectError.self) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateMissingKeyFallsBackToItsDefault() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try Data("{\"exportTempo\": 140}".utf8).write(to: url)

    let loaded = try ProjectState.read(from: url)

    #expect(loaded.exportTempo == 140)
    #expect(loaded.formatVersion == ProjectState.currentFormatVersion)
    #expect(loaded.zoomLevel == 1)
    #expect(loaded.verticalZoom == -1)
    #expect(loaded.playheadCentered)
    #expect(loaded.mixer.isEmpty)
    #expect(loaded.audioFileName == "")
}

@Test func projectStateFromANewerVersionRefusesToLoad() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    let newer = ProjectState.currentFormatVersion + 1
    try Data("{\"formatVersion\": \(newer), \"exportTempo\": 140}".utf8).write(to: url)

    #expect(throws: ProjectError.newerVersion(newer)) {
        try ProjectState.read(from: url)
    }
}

@Test func projectStateSaveWritesSortedPrettyJson() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("project.json")
    try ProjectState().save(to: url)

    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("{\n"))
    #expect(text.contains("\n  \"exportTempo\" : "))
    // Sorted keys: audioFileName precedes exportTempo precedes zoomLevel.
    let audio = try #require(text.range(of: "\"audioFileName\""))
    let tempo = try #require(text.range(of: "\"exportTempo\""))
    let zoom = try #require(text.range(of: "\"zoomLevel\""))
    #expect(audio.lowerBound < tempo.lowerBound)
    #expect(tempo.lowerBound < zoom.lowerBound)
}

// MARK: - parseSelectedGroups

@Test func parseSelectedGroupsDropsUnknownIdsDedupsAndSorts() {
    #expect(ProjectState.parseSelectedGroups("36,0,0,999") == [0, 36])
}

@Test func parseSelectedGroupsOnAnEmptyStringIsEmpty() {
    #expect(ProjectState.parseSelectedGroups("") == [])
    #expect(ProjectState.parseSelectedGroups("   ") == [])
}

@Test func parseSelectedGroupsSortsInEnumeratorOrder() {
    #expect(ProjectState.parseSelectedGroups("33,9,2,19") == [2, 9, 19, 33])
    // 34 and 35 are not group ids; 36 (drums) is the last enumerator.
    #expect(ProjectState.parseSelectedGroups("36,35,34,33") == [33, 36])
}

@Test func parseSelectedGroupsIgnoresJunkAndWhitespace() {
    #expect(ProjectState.parseSelectedGroups(" 7 , banana , -1 , 4 ") == [4, 7])
    #expect(ProjectState.parseSelectedGroups("a,b,c") == [])
}

@Test func parseSelectedGroupsKeepsEveryRealGroupId() {
    let all = InstrumentGroup.allCases.map { String($0.rawValue) }.joined(separator: ",")

    #expect(ProjectState.parseSelectedGroups(all) == InstrumentGroup.allCases.map(\.rawValue))
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: compile errors, `ProjectState` and `ProjectError` undefined.

- [ ] **Step 4: Rewrite `ProjectState.swift`**

Replace the `SessionState` struct (keep `SessionTranscription` and `Workspace` in the file untouched for now) with:

```swift
/// What went wrong opening or saving a project; the app turns each case into the dialog's body.
public enum ProjectError: Error, Equatable, Sendable {
    /// Not a `.neuralsheet` directory holding a `project.json`.
    case notAPackage
    /// `project.json` exists but does not decode; the description says why.
    case unreadable(String)
    /// Written by a version of NeuralSheet with a greater format version than this one's.
    case newerVersion(Int)
    /// `project.json` names an audio file that is not in `audio/`.
    case missingAudio
    /// The package could not be written; the description is the file system's.
    case couldNotWrite(String)
}

/// One project's settings and view state: what `project.json` holds. The audio is a file beside it
/// (`audioFileName`, inside `audio/`) and the transcription a file of its own
/// (``ProjectTranscription``).
///
/// Stored as JSON with sorted keys and indentation so two saves of the same state give the same
/// bytes and the file stays readable by hand. A key that is not there falls back to its default, so a
/// file from an older version still opens; the one thing that refuses is a `formatVersion` greater
/// than ``currentFormatVersion``, since a newer app may have written something this one would
/// silently drop on the next save.
public struct ProjectState: Codable, Equatable, Sendable {
    /// Bump when a change would make an older app misread the file.
    public static let currentFormatVersion = 1

    public var formatVersion = ProjectState.currentFormatVersion
    /// The audio's file name inside `audio/`; empty when the project has no audio.
    public var audioFileName = ""
    /// What the toolbar shows and the MIDI export is named after; nil for a recording.
    public var audioDisplayName: String? = nil
    /// `InstrumentGroup` raw values, in enumerator order. Empty means automatic.
    public var selectedGroups: [Int32] = []
    /// The mix, keyed by program; an absent program is `InstrumentChannelSettings()`.
    public var mixer: [Int: InstrumentChannelSettings] = [:]
    public var exportTempo: Double = 120
    public var gridOffsetSeconds: Double = 0
    public var gridDivision: GridDivision = .sixteenth
    public var snapEnabled = true
    /// The instrument new and reassigned notes go to; nil means the first strip.
    public var targetProgram: Int? = nil

    // View state: written on every save, never what makes the project edited.

    public var workspace: Workspace = .transcribe
    public var playheadSeconds: Double = 0
    public var playheadCentered = true
    public var zoomLevel: Double = 1
    /// −1 means automatic: the piano roll picks the pitch range from the notes.
    public var verticalZoom: Double = -1

    public init() {}

    // MARK: - Files

    /// The state at `url`. `unreadable` for a missing or damaged file, `newerVersion` for one this
    /// version must not touch.
    public static func read(from url: URL) throws -> ProjectState {
        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }

        let state: ProjectState

        do {
            state = try JSONDecoder().decode(ProjectState.self, from: data)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }

        guard state.formatVersion <= currentFormatVersion else {
            throw ProjectError.newerVersion(state.formatVersion)
        }

        return state
    }

    /// Writes the state as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Selected groups

    /// The instrument groups named by a comma-separated list of ids, as the settings menu writes it.
    ///
    /// Ids that are not `InstrumentGroup` raw values are dropped rather than trusted, repeats collapse
    /// and the result comes back in enumerator order, so the same selection always reads the same way
    /// however it was typed.
    public static func parseSelectedGroups(_ csv: String) -> [Int32] {
        let ids = Set(
            csv.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })

        return InstrumentGroup.allCases.map(\.rawValue).filter(ids.contains)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case formatVersion, audioFileName, audioDisplayName, selectedGroups, mixer
        case exportTempo, gridOffsetSeconds, gridDivision, snapEnabled, targetProgram
        case workspace, playheadSeconds, playheadCentered, zoomLevel, verticalZoom
    }

    /// Every key falls back to its default, so a file written by a version that did not have one
    /// still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProjectState()

        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? defaults.formatVersion
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName) ?? defaults.audioFileName
        audioDisplayName = try container.decodeIfPresent(String.self, forKey: .audioDisplayName)
        selectedGroups =
            try container.decodeIfPresent([Int32].self, forKey: .selectedGroups) ?? defaults.selectedGroups
        mixer =
            try container.decodeIfPresent([Int: InstrumentChannelSettings].self, forKey: .mixer)
            ?? defaults.mixer
        exportTempo = try container.decodeIfPresent(Double.self, forKey: .exportTempo) ?? defaults.exportTempo
        gridOffsetSeconds =
            try container.decodeIfPresent(Double.self, forKey: .gridOffsetSeconds) ?? defaults.gridOffsetSeconds
        gridDivision = try container.decodeIfPresent(GridDivision.self, forKey: .gridDivision) ?? defaults.gridDivision
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? defaults.snapEnabled
        targetProgram = try container.decodeIfPresent(Int.self, forKey: .targetProgram)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? defaults.workspace
        playheadSeconds =
            try container.decodeIfPresent(Double.self, forKey: .playheadSeconds) ?? defaults.playheadSeconds
        playheadCentered =
            try container.decodeIfPresent(Bool.self, forKey: .playheadCentered) ?? defaults.playheadCentered
        zoomLevel = try container.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? defaults.zoomLevel
        verticalZoom =
            try container.decodeIfPresent(Double.self, forKey: .verticalZoom) ?? defaults.verticalZoom
    }
}
```

Leave `SessionTranscription` (top of the file) and `Workspace` (bottom) exactly as they are. Delete the file's old header comment about the session.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: all tests pass. (Tests that referenced `SessionState` in other files: none; `grep -rn SessionState Tests Sources` must show nothing.)

- [ ] **Step 6: Commit**

```bash
git add -A app/Packages/NeuralSheetCore
git commit -m "core: ProjectState replaces SessionState

The project file's settings and view state, with a format version that
refuses a newer file, and no audio path: the audio lives inside the package.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `ProjectTranscription`, `ProjectContent`, and `AppPaths` without the session (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectTranscription.swift`
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectContent.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectState.swift` (remove `SessionTranscription`)
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/AppPaths.swift`
- Create: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ProjectContentTests.swift`
- Create: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/AppPathsTests.swift`
- Modify: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ProjectStateTests.swift` (add the transcription test)

**Interfaces:**
- Produces: `public struct ProjectTranscription: Codable, Equatable, Sendable { sourceSampleCount: Int; rawNotes: [NoteEvent]; document: NoteDocument }` with `static func load(from: URL) -> ProjectTranscription?` and `func save(to: URL) throws`.
- Produces: `public struct ProjectContent: Equatable, Sendable` with the memberwise `init(transcription:selectedGroups:mixer:exportTempo:gridOffsetSeconds:gridDivision:snapEnabled:targetProgram:)`.
- Produces: `AppPaths` without `session` and `transcription`, plus `func deleteLegacySessionFiles()` and `func sweepRecordings()`.

- [ ] **Step 1: Write the tests**

Append to `ProjectStateTests.swift`:

```swift
@Test func projectTranscriptionRoundTripsThroughItsOwnFile() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transcription.json")

    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)]
    var document = NoteDocument(events: raw)
    document.commit(document.delete([document.notes[0].id]))
    let transcription = ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: document)

    #expect(ProjectTranscription.load(from: url) == nil)
    try transcription.save(to: url)

    let loaded = try #require(ProjectTranscription.load(from: url))
    #expect(loaded.sourceSampleCount == 16_000)
    #expect(loaded.rawNotes == raw)
    #expect(loaded.document.notes == document.notes)
    #expect(loaded.document.isEdited)
    // The history is not in the file, so the document is equal field by field, not as a whole.
    #expect(!loaded.document.canUndo)
}

@Test func projectTranscriptionGarbageLoadsAsNil() throws {
    let directory = try makeProjectTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transcription.json")
    try Data("5".utf8).write(to: url)

    #expect(ProjectTranscription.load(from: url) == nil)
}
```

Create `ProjectContentTests.swift`:

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private func makeContent() -> ProjectContent {
    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)]

    return ProjectContent(
        transcription: ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw)),
        selectedGroups: [0, 36],
        mixer: [0: InstrumentChannelSettings(gainDb: -3, muted: false, soloed: false)],
        exportTempo: 120,
        gridOffsetSeconds: 0,
        gridDivision: .sixteenth,
        snapEnabled: true,
        targetProgram: 0)
}

@Test func projectContentIsEqualForTheSameState() {
    #expect(makeContent() == makeContent())
}

@Test func projectContentDiffersPerField() {
    var mix = makeContent()
    mix.mixer[0]?.muted = true
    #expect(mix != makeContent())

    var tempo = makeContent()
    tempo.exportTempo = 90
    #expect(tempo != makeContent())

    var groups = makeContent()
    groups.selectedGroups = []
    #expect(groups != makeContent())

    var snap = makeContent()
    snap.snapEnabled = false
    #expect(snap != makeContent())

    var target = makeContent()
    target.targetProgram = 128
    #expect(target != makeContent())

    var notes = makeContent()
    notes.transcription = nil
    #expect(notes != makeContent())
}
```

Create `AppPathsTests.swift`:

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private func makePathsTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePaths(in directory: URL) -> AppPaths {
    AppPaths(
        root: directory.appendingPathComponent("root", isDirectory: true),
        secondaryModels: directory.appendingPathComponent("secondary", isDirectory: true),
        temp: directory.appendingPathComponent("temp", isDirectory: true),
        music: directory.appendingPathComponent("music", isDirectory: true))
}

@Test func deleteLegacySessionFilesRemovesTheTwoAndNothingElse() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    try paths.ensureDirectories()

    let session = paths.root.appendingPathComponent("session.json")
    let transcription = paths.root.appendingPathComponent("transcription.json")
    try Data("{}".utf8).write(to: session)
    try Data("{}".utf8).write(to: transcription)
    try Data("x".utf8).write(to: paths.globalSettings)

    paths.deleteLegacySessionFiles()

    #expect(!FileManager.default.fileExists(atPath: session.path))
    #expect(!FileManager.default.fileExists(atPath: transcription.path))
    #expect(FileManager.default.fileExists(atPath: paths.globalSettings.path))
}

@Test func deleteLegacySessionFilesIsQuietWhenThereAreNone() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)

    paths.deleteLegacySessionFiles()
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}

@Test func sweepRecordingsEmptiesTheFolderAndKeepsIt() throws {
    let directory = try makePathsTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = makePaths(in: directory)
    try paths.ensureDirectories()

    let take = paths.recordings.appendingPathComponent("recorded_audio2026-09-21_10-00-00.wav")
    let downsampled = paths.recordings.appendingPathComponent("recorded_audio2026-09-21_10-00-00_downsampled.wav")
    try Data("x".utf8).write(to: take)
    try Data("x".utf8).write(to: downsampled)

    paths.sweepRecordings()

    #expect(FileManager.default.fileExists(atPath: paths.recordings.path))
    let left = try FileManager.default.contentsOfDirectory(atPath: paths.recordings.path)
    #expect(left.isEmpty)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: compile errors for `ProjectTranscription`, `ProjectContent`, `deleteLegacySessionFiles`, `sweepRecordings`.

- [ ] **Step 3: Create `ProjectTranscription.swift` and remove `SessionTranscription` from `ProjectState.swift`**

```swift
import Foundation

/// The transcription as the project keeps it: the model's own output, the edited document, and the
/// sample count of the audio it belongs to — a package whose audio decodes to another length gets no
/// notes rather than notes against the wrong audio.
///
/// Its own file inside the package (`transcription.json`), written compact: it is megabytes for a
/// long take.
public struct ProjectTranscription: Codable, Equatable, Sendable {
    public var sourceSampleCount: Int
    public var rawNotes: [NoteEvent]
    public var document: NoteDocument

    public init(sourceSampleCount: Int, rawNotes: [NoteEvent], document: NoteDocument) {
        self.sourceSampleCount = sourceSampleCount
        self.rawNotes = rawNotes
        self.document = document
    }

    // MARK: - Files

    /// The transcription at `url`, or nil if there is no file, it cannot be read, or it is not JSON
    /// this version understands: the audio and the settings around it survive.
    public static func load(from url: URL) -> ProjectTranscription? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        return try? JSONDecoder().decode(ProjectTranscription.self, from: data)
    }

    /// Writes the transcription as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
```

Delete the `SessionTranscription` struct from `ProjectState.swift`.

- [ ] **Step 4: Create `ProjectContent.swift`**

```swift
import Foundation

/// What makes a project edited: the fields whose change the user would expect to be asked about
/// before closing. The app builds one from the model after every save and compares it to the one
/// it builds now; the view state (tab, playhead, zoom, note selection) is not in it, so moving the
/// playhead never puts the dot in the close button, and undoing back to the saved notes clears it.
///
/// The audio is compared by the app on the source object itself, since the audio type is the app's.
public struct ProjectContent: Equatable, Sendable {
    public var transcription: ProjectTranscription?
    public var selectedGroups: [Int32]
    public var mixer: [Int: InstrumentChannelSettings]
    public var exportTempo: Double
    public var gridOffsetSeconds: Double
    public var gridDivision: GridDivision
    public var snapEnabled: Bool
    public var targetProgram: Int?

    public init(
        transcription: ProjectTranscription?,
        selectedGroups: [Int32],
        mixer: [Int: InstrumentChannelSettings],
        exportTempo: Double,
        gridOffsetSeconds: Double,
        gridDivision: GridDivision,
        snapEnabled: Bool,
        targetProgram: Int?
    ) {
        self.transcription = transcription
        self.selectedGroups = selectedGroups
        self.mixer = mixer
        self.exportTempo = exportTempo
        self.gridOffsetSeconds = gridOffsetSeconds
        self.gridDivision = gridDivision
        self.snapEnabled = snapEnabled
        self.targetProgram = targetProgram
    }
}
```

- [ ] **Step 5: Edit `AppPaths.swift`**

Remove the `session` and `transcription` properties and their two assignments in `init`. Replace the `root`/`globalSettings` doc comment block accordingly and add, after `ensureDirectories()`:

```swift
    /// The two files the autosaved session used to be (`session.json`, `transcription.json`,
    /// beside the settings): a project file holds that now, so they go at launch. Quiet when there
    /// are none.
    public func deleteLegacySessionFiles() {
        for name in ["session.json", "transcription.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Empties the recordings folder. A take lives there only while its project is open -- a save
    /// copies it into the package and a close deletes it -- so anything there at launch is a
    /// crash's leftover. The folder itself stays.
    public func sweepRecordings() {
        let manager = FileManager.default

        guard let entries = try? manager.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) else {
            return
        }

        for entry in entries {
            try? manager.removeItem(at: entry)
        }
    }
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: all pass. `grep -rn "SessionTranscription\|paths.session\|paths.transcription" app/Packages` shows nothing.

- [ ] **Step 7: Commit**

```bash
git add -A app/Packages/NeuralSheetCore
git commit -m "core: ProjectTranscription, ProjectContent, and AppPaths without the session

The transcription file keeps its shape under the project's name; the
content value is what the dirty rule compares; the session URLs go, with
a launch-time cleanup of the legacy files and the recordings folder.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `ProjectPackage` (core)

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectPackage.swift`
- Create: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ProjectPackageTests.swift`

**Interfaces:**
- Produces: `public struct ProjectPackage: Sendable { var state: ProjectState; var transcription: ProjectTranscription?; init(state:transcription:) }`, `static let pathExtension = "neuralsheet"`, `static let recordingFileName = "recording.wav"`, `static func read(from url: URL) throws -> (package: ProjectPackage, audioURL: URL?)`, `func write(to url: URL, audioSource: URL?) throws`, `static func audioURL(in package: URL, fileName: String) -> URL`.

- [ ] **Step 1: Write the tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private func makePackageTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NeuralSheetCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeAudio(in directory: URL, name: String = "take.wav", bytes: String = "RIFF-not-really") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(bytes.utf8).write(to: url)
    return url
}

private func makePackage(audioFileName: String, withTranscription: Bool) -> ProjectPackage {
    var state = ProjectState()
    state.audioFileName = audioFileName
    state.audioDisplayName = audioFileName.isEmpty ? nil : "take"
    state.exportTempo = 100

    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)]
    let transcription = withTranscription
        ? ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw))
        : nil

    return ProjectPackage(state: state, transcription: transcription)
}

@Test func packageRoundTripsWithAudioAndTranscription() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    let package = makePackage(audioFileName: "take.wav", withTranscription: true)
    try package.write(to: url, audioSource: audio)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.state == package.state)
    #expect(read.package.transcription == package.transcription)
    let audioURL = try #require(read.audioURL)
    #expect(audioURL == ProjectPackage.audioURL(in: url, fileName: "take.wav"))
    #expect(try Data(contentsOf: audioURL) == Data("RIFF-not-really".utf8))
}

@Test func packageWithoutATranscriptionHasNoTranscriptionFile() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)

    #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("transcription.json").path))
    #expect(try ProjectPackage.read(from: url).package.transcription == nil)
}

@Test func packageWithoutAudioReadsBackWithNoAudioURL() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Empty.neuralsheet")

    try makePackage(audioFileName: "", withTranscription: false).write(to: url, audioSource: nil)

    let read = try ProjectPackage.read(from: url)
    #expect(read.audioURL == nil)
    #expect(read.package.state.audioFileName == "")
}

@Test func packageWriteReplacesAnExistingPackage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)
    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription == nil)
    #expect(read.audioURL != nil)
}

@Test func packageWriteCopiesAudioFromInsideTheDestination() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)
    try FileManager.default.removeItem(at: audio)

    // The unchanged-audio case: the source is the package's own copy.
    let inside = ProjectPackage.audioURL(in: url, fileName: "take.wav")
    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: inside)

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription != nil)
    #expect(try Data(contentsOf: #require(read.audioURL)) == Data("RIFF-not-really".utf8))
}

@Test func packageWriteFailureLeavesThePreviousPackageIntact() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)

    let missing = directory.appendingPathComponent("gone.wav")
    #expect(throws: ProjectError.self) {
        try makePackage(audioFileName: "gone.wav", withTranscription: false).write(to: url, audioSource: missing)
    }

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription != nil)
    #expect(read.package.state.audioFileName == "take.wav")
    // No temporary directory is left beside it.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(siblings.sorted() == ["Song.neuralsheet", "take.wav"])
}

@Test func packageReadRefusesWhatIsNotAPackage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let plainFile = directory.appendingPathComponent("Song.neuralsheet")
    try Data("x".utf8).write(to: plainFile)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: plainFile) }

    let wrongExtension = directory.appendingPathComponent("Song.txt", isDirectory: true)
    try FileManager.default.createDirectory(at: wrongExtension, withIntermediateDirectories: true)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: wrongExtension) }

    let emptyFolder = directory.appendingPathComponent("Empty.neuralsheet", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    #expect(throws: ProjectError.notAPackage) { try ProjectPackage.read(from: emptyFolder) }
}

@Test func packageReadReportsUnreadableState() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Song.neuralsheet", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url.appendingPathComponent("project.json"))

    #expect(throws: ProjectError.self) { try ProjectPackage.read(from: url) }

    do {
        _ = try ProjectPackage.read(from: url)
    } catch let ProjectError.unreadable(reason) {
        #expect(!reason.isEmpty)
    }
}

@Test func packageReadReportsMissingAudio() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: false).write(to: url, audioSource: audio)
    try FileManager.default.removeItem(at: ProjectPackage.audioURL(in: url, fileName: "take.wav"))

    #expect(throws: ProjectError.missingAudio) { try ProjectPackage.read(from: url) }
}

@Test func packageReadKeepsTheRestWhenTheTranscriptionIsGarbage() throws {
    let directory = try makePackageTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try makeAudio(in: directory)
    let url = directory.appendingPathComponent("Song.neuralsheet")

    try makePackage(audioFileName: "take.wav", withTranscription: true).write(to: url, audioSource: audio)
    try Data("5".utf8).write(to: url.appendingPathComponent("transcription.json"))

    let read = try ProjectPackage.read(from: url)
    #expect(read.package.transcription == nil)
    #expect(read.package.state.exportTempo == 100)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: compile errors, `ProjectPackage` undefined.

- [ ] **Step 3: Create `ProjectPackage.swift`**

```swift
import Foundation

/// A project on disk: a `Name.neuralsheet` folder the Finder shows as one file, holding
/// `project.json` (``ProjectState``), `transcription.json` (``ProjectTranscription``, absent
/// without a finished transcription) and `audio/<file>` (the audio, named in the state).
///
/// A write builds the whole package in a temporary directory beside the destination and swaps it
/// in with `replaceItemAt`, so a failure at any step leaves what was there untouched. The audio is
/// copied with `copyItem`, which on APFS is a clone: saving after an edit costs the JSON only.
public struct ProjectPackage: Sendable {
    public static let pathExtension = "neuralsheet"
    /// A recorded take's name inside the package; a dropped file keeps its own.
    public static let recordingFileName = "recording.wav"

    static let stateFileName = "project.json"
    static let transcriptionFileName = "transcription.json"
    static let audioDirectoryName = "audio"

    public var state: ProjectState
    public var transcription: ProjectTranscription?

    public init(state: ProjectState, transcription: ProjectTranscription?) {
        self.state = state
        self.transcription = transcription
    }

    /// Where the audio named `fileName` sits inside the package at `package`.
    public static func audioURL(in package: URL, fileName: String) -> URL {
        package.appendingPathComponent(audioDirectoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    // MARK: - Reading

    /// The package at `url`, and where its audio is (nil for a project without audio, checked to
    /// exist otherwise).
    ///
    /// `notAPackage` for anything that is not a `.neuralsheet` directory with a `project.json`;
    /// `unreadable` and `newerVersion` from the state; `missingAudio` when the state names a file
    /// that is not there. A transcription that cannot be read is dropped alone.
    public static func read(from url: URL) throws -> (package: ProjectPackage, audioURL: URL?) {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default

        guard url.pathExtension.lowercased() == pathExtension,
            manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            manager.fileExists(atPath: url.appendingPathComponent(stateFileName).path)
        else {
            throw ProjectError.notAPackage
        }

        let state = try ProjectState.read(from: url.appendingPathComponent(stateFileName))
        let transcription = ProjectTranscription.load(from: url.appendingPathComponent(transcriptionFileName))

        var audioURL: URL?

        if !state.audioFileName.isEmpty {
            let audio = audioURL(in: url, fileName: state.audioFileName)

            guard manager.fileExists(atPath: audio.path) else { throw ProjectError.missingAudio }

            audioURL = audio
        }

        return (ProjectPackage(state: state, transcription: transcription), audioURL)
    }

    // MARK: - Writing

    /// Writes the package to `url`, replacing whatever is there. `audioSource` is copied to
    /// `audio/<state.audioFileName>`, and may be inside the destination itself (the copy is made
    /// before the swap); nil writes no audio, and then `audioFileName` must be empty.
    public func write(to url: URL, audioSource: URL?) throws {
        precondition((audioSource == nil) == state.audioFileName.isEmpty,
                     "audioSource and audioFileName must agree")

        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        // Beside the destination: the same volume, so the swap is a rename and the copy a clone.
        let staging = parent.appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)", isDirectory: true)

        defer { try? manager.removeItem(at: staging) }

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)

            if let audioSource {
                let audioDirectory = staging.appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                try manager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                try manager.copyItem(at: audioSource, to: audioDirectory.appendingPathComponent(state.audioFileName))
            }

            try state.save(to: staging.appendingPathComponent(Self.stateFileName))

            if let transcription {
                try transcription.save(to: staging.appendingPathComponent(Self.transcriptionFileName))
            }

            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
        } catch let error as ProjectError {
            throw error
        } catch {
            throw ProjectError.couldNotWrite(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -20`
Expected: all pass. If `replaceItemAt` complains about the staging name, use `options: []` and keep the staging directory beside the destination; the test `packageWriteFailureLeavesThePreviousPackageIntact` checks the staging directory is gone afterwards.

- [ ] **Step 5: Commit**

```bash
git add -A app/Packages/NeuralSheetCore
git commit -m "core: ProjectPackage reads and writes the .neuralsheet package

Built in a staging directory beside the destination and swapped in
atomically, so a failed save never leaves a half-written project.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Remove the session from the app; launch cleanup (app)

**Files:**
- Delete: `app/NeuralSheet/App/AppModel+Session.swift`
- Create: `app/NeuralSheet/App/Persistence.swift`
- Modify: `app/NeuralSheet/App/AppModel.swift` (`restoreAudio`, `load(url:restoringSession:)`, `install`, `init`)
- Modify: `app/NeuralSheet/UI/MainView.swift` (`appear()`)

**Interfaces:**
- Produces: `Persistence` with `init(model:)` and `start()` only; `AppModel.saveGlobalSettings()`, `AppModel.deleteMidiScratch()` (moved), `AppModel.installSource(_:)` (was `private install`), `AppModel.load(url:)` (was `load(url:restoringSession:)`).
- Removed: `sessionSnapshot()`, `transcriptionSnapshot()`, `saveSession*`, `restoreSession()`, `restoreAudio(url:)`, `Persistence.restoreOnce()`.

- [ ] **Step 1: Create `Persistence.swift` with the settings half**

```swift
import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// The global settings (inventory §8.1): written on every change, and once more as the app
/// terminates, when the MIDI drag scratch is removed too. The session that used to be written
/// beside them is gone: a project file holds that now (`AppModel+Project.swift`).
extension AppModel {
    /// Writes every key (§8.1), so the file always lists what the app is using.
    func saveGlobalSettings() {
        try? paths.ensureDirectories()
        try? settings.save(to: paths.globalSettings)
    }

    /// What the drag button left in the temp directory goes with the app (§8.3).
    func deleteMidiScratch() {
        try? FileManager.default.removeItem(at: paths.midiScratch)
    }
}

/// Keeps the settings file in step with the model. One per app, created beside the model.
@MainActor final class Persistence {
    private let model: AppModel
    private var terminateObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
    }

    /// Starts watching. Call once, when the first window appears.
    func start() {
        guard terminateObserver == nil else { return }

        Tooltips.enabled = model.settings.tooltipsVisible
        observeSettings()

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminate()
            }
        }
    }

    /// Whatever the observer below has not caught up with yet: the settings write is
    /// asynchronous, and the app is about to stop running the loop it is queued on.
    private func terminate() {
        model.saveGlobalSettings()
        model.deleteMidiScratch()
    }

    /// Every setter of `NnGlobalSettings` rewrote the file; here the file follows the struct.
    private func observeSettings() {
        withObservationTracking {
            _ = model.settings
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                Tooltips.enabled = self.model.settings.tooltipsVisible
                self.model.saveGlobalSettings()
                self.observeSettings()
            }
        }
    }
}
```

- [ ] **Step 2: Delete `AppModel+Session.swift`**

```bash
git rm app/NeuralSheet/App/AppModel+Session.swift
```

- [ ] **Step 3: Edit `AppModel.swift`**

In `init`, after `modelStore.deleteStalePartFiles()`, add:

```swift
        // The autosaved session is gone with projects; its files and any take a crash left behind
        // go at launch.
        paths.deleteLegacySessionFiles()
        paths.sweepRecordings()
```

Replace `restoreAudio(url:)`, `load(url:restoringSession:)` and `install(_:)` with:

```swift
    private func load(url: URL) {
        let audio: SourceAudio

        do {
            audio = try AudioFileLoader.load(url: url, deviceRate: engine.sampleRate)
        } catch {
            showError(
                "Could not load the audio file.",
                "Check your file format (Accepted formats: .wav, .aiff, .flac, .mp3, .ogg).")
            return
        }

        installSource(audio)
    }

    /// Hands a take to the engine and moves to `audioLoaded`. The pipeline's and the project's
    /// (`AppModel+Project.swift`), never a view's.
    func installSource(_ audio: SourceAudio) {
        source = audio
        duration = audio.duration
        engine.setSource(audio)
        playheadSeconds = 0
        isPlaying = false
        transition(to: .audioLoaded)
    }
```

Update the call in `loadAudio(url:)` to `load(url: url)` and the one in `stopRecording()` to `installSource(take)`. Delete the doc comment on `restoreAudio` and remove the mention of `restoringSession` in `load`'s comment. Also update the class doc comment's last paragraph ("Persistence is Task 20's...") to: "The settings are written by `Persistence`; the project by `AppModel+Project.swift`."

- [ ] **Step 4: Edit `MainView.appear()`**

Remove `persistence.restoreOnce()`; keep `persistence.start()`. Update the doc comment: "The dialogs first, then the settings autosave and the shortcuts."

- [ ] **Step 5: Build**

Run: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error|warning: .*NeuralSheet/|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **`, no warnings in our files. `grep -rn "sessionSnapshot\|restoreSession\|SessionState\|SessionTranscription" app/NeuralSheet` shows nothing.

- [ ] **Step 6: Commit**

```bash
git add -A app/NeuralSheet
git commit -m "app: the autosaved session goes

A project file will hold what it held. The settings keep their observer
in Persistence.swift; the legacy session files and a crash's leftover
takes are deleted at launch.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Project state, snapshot, edited flag, New (app)

**Files:**
- Modify: `app/NeuralSheet/App/AppModel.swift` (stored project properties)
- Create: `app/NeuralSheet/App/AppModel+Project.swift`
- Create: `app/NeuralSheet/App/ProjectTracker.swift`
- Modify: `app/NeuralSheet/App/MainWindow.swift` (title, URL, edited)
- Modify: `app/NeuralSheet/UI/MainView.swift` (tracker, navigation title)

**Interfaces:**
- Consumes: `ProjectContent`, `ProjectTranscription`, `ProjectState`, `ProjectPackage` from Tasks 1–3; `installSource`, `resetMixerSettingsForLaunch`, `clearNow`, `installDocument`, `setTargetProgram`, `setWorkspace`, `seek`, `setGain/Muted/Soloed`, `normalised(_:)`.
- Produces on `AppModel`: `var projectURL: URL?`, `var isProjectEdited: Bool`, `var projectTitle: String`, `var canChangeProject: Bool`, `var canSaveProject: Bool`, `var canRevertProject: Bool`, `func projectContent() -> ProjectContent`, `func projectState(audioFileName:) -> ProjectState`, `func transcriptionSnapshot() -> ProjectTranscription?`, `func computeProjectEdited() -> Bool`, `func replaceWithEmpty()`, `func markProjectSaved(audioFileName:)`, `func newProject()` (review comes in Task 6, so for now `newProject` replaces at once). `ProjectTracker(model:windowController:)`, `.start()`. `MainWindowController.setDocument(url:edited:)`.

- [ ] **Step 1: Add the stored properties to `AppModel.swift`**

After the `// MARK: - Export and settings` block, add:

```swift
    // MARK: - Project

    /// Where the project is saved, or nil for an untitled one. Only `AppModel+Project.swift`
    /// writes it.
    var projectURL: URL?

    /// Content differs from what was last saved: the dot in the close button. Kept by
    /// `ProjectTracker`; the commands that need the truth now call ``computeProjectEdited()``.
    var isProjectEdited = false

    /// What the last save (or the empty project) held; the dirty rule compares against it.
    @ObservationIgnored var lastSavedContent: ProjectContent?

    /// The take as of the last save: another object means the audio changed. Weak, so the buffer
    /// of a take that has been replaced is not kept alive for the comparison.
    @ObservationIgnored weak var lastSavedSource: SourceAudio?

    /// The audio's name inside the saved package, for the unchanged-audio copy on the next save.
    @ObservationIgnored var lastSavedAudioFileName = ""

    /// Installed by the welcome view and the main view: shows the project window (and dismisses
    /// the welcome window), and the reverse. Nil before a window exists.
    @ObservationIgnored var showProjectWindow: (() -> Void)?
    @ObservationIgnored var showWelcomeWindow: (() -> Void)?
```

- [ ] **Step 2: Create `AppModel+Project.swift`**

```swift
import AppKit
import Foundation
import NeuralSheetCore

/// The project's lifecycle (projects design §4): one project at a time, in the one model. New,
/// Open, Save, Save As, Revert and Close all go through here; the dirty rule (§4.1) compares the
/// content now with the content last saved.
extension AppModel {
    // MARK: - State

    /// The window title: the file's display name, or "Untitled".
    var projectTitle: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Save, Save As, New, Open, Revert and Close: not while recording or transcribing.
    var canChangeProject: Bool { state != .recording && state != .processing }

    var canSaveProject: Bool { canChangeProject }

    var canRevertProject: Bool { canChangeProject && projectURL != nil && isProjectEdited }

    // MARK: - Snapshots

    /// The transcription as it stands, or nil until one has finished.
    func transcriptionSnapshot() -> ProjectTranscription? {
        guard state == .populated, let document, let source else { return nil }

        return ProjectTranscription(sourceSampleCount: source.mono16k.count,
                                    rawNotes: transcription.rawNotes,
                                    document: document)
    }

    /// The content the dirty rule compares (§3.4).
    func projectContent() -> ProjectContent {
        ProjectContent(transcription: transcriptionSnapshot(),
                       selectedGroups: selectedGroups.map(\.rawValue),
                       mixer: mixer.settings,
                       exportTempo: exportTempo,
                       gridOffsetSeconds: editor.grid.offsetSeconds,
                       gridDivision: editor.grid.division,
                       snapEnabled: editor.snapEnabled,
                       targetProgram: editor.targetProgram)
    }

    /// Everything `project.json` holds, ready to be written.
    func projectState(audioFileName: String) -> ProjectState {
        var state = ProjectState()
        state.audioFileName = audioFileName
        state.audioDisplayName = droppedFileName
        state.selectedGroups = selectedGroups.map(\.rawValue)
        state.mixer = mixer.settings
        state.exportTempo = exportTempo
        state.gridOffsetSeconds = editor.grid.offsetSeconds
        state.gridDivision = editor.grid.division
        state.snapEnabled = editor.snapEnabled
        state.targetProgram = editor.targetProgram
        state.workspace = workspace
        state.playheadSeconds = playheadSeconds
        state.playheadCentered = followPlayhead
        state.zoomLevel = zoomLevel
        state.verticalZoom = verticalZoom

        return state
    }

    /// The truth now, for the commands; ``isProjectEdited`` follows it a moment later.
    func computeProjectEdited() -> Bool {
        source !== lastSavedSource || projectContent() != lastSavedContent
    }

    /// After a save or an open: what is there now is what the file has.
    func markProjectSaved(audioFileName: String) {
        lastSavedContent = projectContent()
        lastSavedSource = source
        lastSavedAudioFileName = audioFileName

        if isProjectEdited {
            isProjectEdited = false
        }
    }

    // MARK: - Replacing

    /// The empty project: no audio, no notes, the selection automatic, the mix and the grid at
    /// their defaults, untitled and clean. Every way out of a project ends here.
    func replaceWithEmpty() {
        clearNow()
        resetMixerSettingsForLaunch()
        selectedGroups = []
        editor = EditorState()
        followPlayhead = true
        zoomLevel = 1
        verticalZoom = -1
        projectURL = nil
        markProjectSaved(audioFileName: "")
    }

    /// File → New Project, and the welcome window's Create.
    func newProject() {
        guard canChangeProject else { return }

        replaceWithEmpty()
    }
}
```

- [ ] **Step 3: Create `ProjectTracker.swift`**

```swift
import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// Keeps `AppModel.isProjectEdited` and the window's document state in step with the model
/// (projects design §5.2): re-reads the content snapshot 100 ms after the last change to any of
/// its fields -- a few thousand note structs at most, never per frame -- and pushes the title,
/// the represented file and the dot to the window. One per main view.
@MainActor final class ProjectTracker {
    private let model: AppModel
    private let windowController: MainWindowController
    private var timer: Timer?

    /// Between the last change and the comparison.
    static let debounce: TimeInterval = 0.1

    init(model: AppModel, windowController: MainWindowController) {
        self.model = model
        self.windowController = windowController
    }

    /// Call once, when the view appears.
    func start() {
        observeContent()
        observeDocumentState()
        refresh()
        pushDocumentState()
    }

    // MARK: - Content

    /// Reads every field the snapshot is made of, so the next write to any of them re-arms the
    /// timer; the timer is re-armed only once it has fired, so a fader being dragged compares
    /// ten times a second, not once per pixel.
    private func observeContent() {
        withObservationTracking {
            _ = model.projectContent()
            _ = model.source
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                self.schedule()
                self.observeContent()
            }
        }
    }

    private func schedule() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: Self.debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.refresh()
            }
        }

        // `.common`, so a change made from a menu or during a drag is still noticed.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let edited = model.computeProjectEdited()

        if edited != model.isProjectEdited {
            model.isProjectEdited = edited
        }
    }

    // MARK: - Window

    private func observeDocumentState() {
        withObservationTracking {
            _ = model.projectURL
            _ = model.isProjectEdited
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                self.pushDocumentState()
                self.observeDocumentState()
            }
        }
    }

    private func pushDocumentState() {
        windowController.setDocument(url: model.projectURL, edited: model.isProjectEdited)
    }
}
```

- [ ] **Step 4: Edit `MainWindow.swift`**

Add to `MainWindowController`, after the `window` property:

```swift
    /// The represented file and the edited flag, kept here so a window attached later gets them.
    private var documentURL: URL?
    private var documentEdited = false
```

Replace `attach` and add `setDocument`:

```swift
    /// Once, when the view lands in its window.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }

        self.window = window
        applyDocument()
    }

    /// The proxy icon (and its Finder menu) and the dot in the close button, from AppKit's own
    /// properties. The title is SwiftUI's (`navigationTitle` on the main view).
    func setDocument(url: URL?, edited: Bool) {
        documentURL = url
        documentEdited = edited
        applyDocument()
    }

    private func applyDocument() {
        guard let window else { return }

        if window.representedURL != documentURL {
            window.representedURL = documentURL
        }

        if window.isDocumentEdited != documentEdited {
            window.isDocumentEdited = documentEdited
        }
    }
```

- [ ] **Step 5: Edit `MainView.swift`**

Add a state property and create the tracker beside the shortcuts:

```swift
    @State private var tracker: ProjectTracker
```

In `init`, after `_shortcuts`:

```swift
        let controller = MainWindowController()
        _windowController = State(initialValue: controller)
        _tracker = State(initialValue: ProjectTracker(model: model, windowController: controller))
```

and change the `windowController` declaration to `@State private var windowController: MainWindowController` (no default). Add `.navigationTitle(model.projectTitle)` right after `.frame(minWidth:minHeight:)` in `body`. In `appear()`, after `persistence.start()`, add `tracker.start()`.

- [ ] **Step 6: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`, warning-free in our files. Launch the app (`open app/build/Debug/NeuralSheet.app` or from Xcode): the title reads "Untitled"; dropping an audio file puts the dot in the close button; no session is restored.

- [ ] **Step 7: Commit**

```bash
git add -A app/NeuralSheet
git commit -m "app: the project's state, its content snapshot and the edited flag

The dirty rule compares the content now with the content last saved, so
undoing back to the saved notes clears the dot; the tab, the playhead and
the zoom never set it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Save, Save As, Open, Revert, Close, the review sheet, the document type (app)

**Files:**
- Modify: `app/NeuralSheet/App/AppModel.swift` (dialog closures)
- Modify: `app/NeuralSheet/App/AppModel+Project.swift`
- Modify: `app/NeuralSheet/App/Dialogs.swift`
- Modify: `app/NeuralSheet/UI/MainView.swift` (`appear()`)
- Create: `app/NeuralSheet/App/ProjectType.swift`
- Modify: `app/Info.plist`

**Interfaces:**
- Produces on `AppModel`: `enum SaveReviewChoice { case save, discard, cancel }`, `var presentSaveReview: ((String, @escaping (SaveReviewChoice) -> Void) -> Void)?`, `var presentRevert: ((String, @escaping (Bool) -> Void) -> Void)?`, `@discardableResult func saveProject() -> Bool`, `@discardableResult func saveProjectAs() -> Bool`, `func openProject(url: URL, reviewing: Bool = true)`, `func openProjectFromPanel()`, `func revertProject()`, `func closeProject(then: @escaping () -> Void)`, `func reviewProject(then: @escaping () -> Void, cancelled: (() -> Void)? = nil)`; `newProject()` now reviews. `UTType.neuralSheetProject`. `Dialogs.installProjectDialogs(on:window:)`.

- [ ] **Step 1: Create `ProjectType.swift`**

```swift
import UniformTypeIdentifiers

extension UTType {
    /// The `.neuralsheet` package, as `app/Info.plist` exports it.
    static let neuralSheetProject = UTType(exportedAs: "com.quassum.neuralsheet.project", conformingTo: .package)
}
```

- [ ] **Step 2: Add the document type to `app/Info.plist`**

Inside the top-level `<dict>`, after the Sparkle keys:

```xml
	<!-- The project package. Xcode merges this with the generated Info.plist. -->
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>NeuralSheet Project</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSTypeIsPackage</key>
			<true/>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.quassum.neuralsheet.project</string>
			</array>
		</dict>
	</array>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.quassum.neuralsheet.project</string>
			<key>UTTypeDescription</key>
			<string>NeuralSheet Project</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>com.apple.package</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>neuralsheet</string>
				</array>
			</dict>
		</dict>
	</array>
```

- [ ] **Step 3: Add the dialog closures to `AppModel.swift`**

In the `// MARK: - Dialogs` block, after `presentConfirm`:

```swift
    /// What the save-changes sheet came back with.
    enum SaveReviewChoice {
        case save, discard, cancel
    }

    /// Installed by the view layer: `(project title, completion)` for the standard "Do you want
    /// to save the changes…" sheet. Nil proceeds without saving, which is what happens before a
    /// window exists.
    @ObservationIgnored var presentSaveReview: ((String, @escaping (SaveReviewChoice) -> Void) -> Void)?

    /// Installed by the view layer: `(project title, completion)` for "Do you want to revert…".
    /// Nil declines.
    @ObservationIgnored var presentRevert: ((String, @escaping (Bool) -> Void) -> Void)?
```

- [ ] **Step 4: Add the sheets to `Dialogs.swift`**

```swift
    /// Points `model.presentSaveReview` and `model.presentRevert` at the window.
    static func installProjectDialogs(on model: AppModel, window: @escaping () -> NSWindow?) {
        model.presentSaveReview = { title, completion in
            saveReview(title: title, on: window(), completion: completion)
        }
        model.presentRevert = { title, completion in
            revert(title: title, on: window(), completion: completion)
        }
    }

    /// AppKit's own save-changes question, with its button order: Save (Return), Cancel (Escape),
    /// Don't Save (⌘D).
    static func saveReview(title: String, on window: NSWindow?,
                           completion: @escaping (AppModel.SaveReviewChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the document “\(title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]

        let choice: (NSApplication.ModalResponse) -> AppModel.SaveReviewChoice = { response in
            switch response {
            case .alertFirstButtonReturn: .save
            case .alertThirdButtonReturn: .discard
            default: .cancel
            }
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(choice(response))
            }
        } else {
            DispatchQueue.main.async {
                completion(choice(alert.runModal()))
            }
        }
    }

    /// AppKit's own revert question: Revert, Cancel (Return, so a stray key is safe).
    static func revert(title: String, on window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to revert to the most recently saved version of “\(title)”?"
        alert.informativeText = "Your current changes will be lost."
        alert.alertStyle = .warning

        let revert = alert.addButton(withTitle: "Revert")
        revert.hasDestructiveAction = true
        revert.keyEquivalent = ""

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

In `MainView.appear()`, after `Dialogs.installConfirm(...)`, add:

```swift
        Dialogs.installProjectDialogs(on: model) { [windowController] in windowController.window }
```

- [ ] **Step 5: Add the commands to `AppModel+Project.swift`**

Replace `newProject()` and append the rest:

```swift
    /// File → New Project, and the welcome window's Create: the current project is reviewed
    /// first (nothing to ask when it is clean, as from the welcome window).
    func newProject() {
        guard canChangeProject else { return }

        reviewProject { [weak self] in
            self?.replaceWithEmpty()
        }
    }

    // MARK: - Review

    /// Runs `proceed` at once when the project is clean, otherwise after the standard sheet:
    /// Save writes first (the save panel included, for an untitled project) and proceeds only
    /// when the write succeeded; Don't Save proceeds; Cancel runs `cancelled`.
    func reviewProject(then proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard computeProjectEdited(), let presentSaveReview else {
            proceed()
            return
        }

        presentSaveReview(projectTitle) { [weak self] choice in
            guard let self else { return }

            switch choice {
            case .save:
                if saveProject() {
                    proceed()
                } else {
                    cancelled?()
                }
            case .discard:
                proceed()
            case .cancel:
                cancelled?()
            }
        }
    }

    // MARK: - Saving

    /// File → Save: the save panel for an untitled project, the file itself otherwise. True when
    /// the file was written.
    @discardableResult
    func saveProject() -> Bool {
        guard canSaveProject else { return false }
        guard let projectURL else { return saveProjectAs() }

        return writeProject(to: projectURL)
    }

    /// File → Save As…: a save panel titled "Save Project" beside the current file, or in the
    /// Music folder for an untitled one, named after the project or its audio.
    @discardableResult
    func saveProjectAs() -> Bool {
        guard canSaveProject else { return false }

        let panel = NSSavePanel()
        // `message` is what the modern panel shows; `title` is kept for the accessibility name.
        panel.title = "Save Project"
        panel.message = "Save Project"
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? paths.musicFolder
        panel.nameFieldStringValue = projectURL != nil ? projectTitle : (droppedFileName ?? "Untitled")
        panel.allowedContentTypes = [.neuralSheetProject]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        return writeProject(to: url)
    }

    /// The write itself. The audio comes from the package's own copy when it has not changed
    /// since the last save (an APFS clone, so an edit costs the JSON only), else from where the
    /// take was loaded or recorded.
    private func writeProject(to url: URL) -> Bool {
        var audioFileName = ""
        var audioSource: URL?

        if let source {
            audioFileName = source.droppedFileName == nil
                ? ProjectPackage.recordingFileName
                : (source.sourcePath?.lastPathComponent ?? ProjectPackage.recordingFileName)

            if source === lastSavedSource, let projectURL, !lastSavedAudioFileName.isEmpty {
                audioFileName = lastSavedAudioFileName
                audioSource = ProjectPackage.audioURL(in: projectURL, fileName: audioFileName)
            } else if let path = source.sourcePath {
                audioSource = path
            } else {
                showError("Could not save the project.", "The audio has no file to copy.")
                return false
            }
        }

        let package = ProjectPackage(state: projectState(audioFileName: audioFileName),
                                     transcription: transcriptionSnapshot())

        do {
            try package.write(to: url, audioSource: audioSource)
        } catch {
            showError("Could not save the project.", AppModel.describe(error))
            return false
        }

        projectURL = url
        markProjectSaved(audioFileName: audioFileName)
        noteRecentProject(url)

        return true
    }

    // MARK: - Opening

    /// File → Open…: a panel titled "Open Project", the package type only.
    func openProjectFromPanel() {
        guard canChangeProject else { return }

        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Open Project"
        panel.allowedContentTypes = [.neuralSheetProject]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        openProject(url: url)
    }

    /// Opens the package at `url` in place of the current project. Read and decoded *before* the
    /// current project is touched, so a bad file costs nothing; a failure is one dialog.
    /// `reviewing: false` skips the save question (Revert's case).
    func openProject(url: URL, reviewing: Bool = true) {
        guard canChangeProject else { return }

        let package: ProjectPackage
        var audio: SourceAudio?

        do {
            let read = try ProjectPackage.read(from: url)
            package = read.package

            if let audioURL = read.audioURL {
                audio = try AudioFileLoader.load(url: audioURL,
                                                 deviceRate: engine.sampleRate,
                                                 namedAfterFile: package.state.audioDisplayName != nil)
            }
        } catch {
            showError("Could not open the project.", AppModel.describe(error))
            return
        }

        let install = { [weak self] in
            self?.installProject(package, audio: audio, url: url)
        }

        if reviewing {
            reviewProject(then: install)
        } else {
            install()
        }
    }

    /// Past the checks: the empty project first, then the settings, the audio, the notes (only
    /// against the very audio they were made from), the view state.
    private func installProject(_ package: ProjectPackage, audio: SourceAudio?, url: URL) {
        replaceWithEmpty()

        let saved = package.state
        selectedGroups = AppModel.normalised(saved.selectedGroups.compactMap(InstrumentGroup.init(rawValue:)))

        // The mix is a whole: what the file has replaces what is there, program by program.
        for (program, channel) in saved.mixer {
            setGain(program: program, db: channel.gainDb)
            setMuted(program: program, channel.muted)
            setSoloed(program: program, channel.soloed)
        }

        exportTempo = saved.exportTempo
        editor.grid.offsetSeconds = max(0, saved.gridOffsetSeconds)
        editor.grid.division = saved.gridDivision
        editor.snapEnabled = saved.snapEnabled
        followPlayhead = saved.playheadCentered
        zoomLevel = saved.zoomLevel
        verticalZoom = saved.verticalZoom

        if let audio {
            installSource(audio)
        }

        if let audio, let transcription = package.transcription, audio.mono16k.count == transcription.sourceSampleCount {
            installDocument(rawNotes: transcription.rawNotes, document: transcription.document)
            transition(to: .populated)

            if let target = saved.targetProgram {
                setTargetProgram(target)
            }

            setWorkspace(saved.workspace)
        }

        if state.canPlay, saved.playheadSeconds > 0 {
            seek(toSeconds: saved.playheadSeconds)
        }

        projectURL = url
        markProjectSaved(audioFileName: saved.audioFileName)
        noteRecentProject(url)
    }

    // MARK: - Revert and close

    /// File → Revert to Saved…: the standard question, then the file again without the review.
    func revertProject() {
        guard canRevertProject, let url = projectURL, let presentRevert else { return }

        presentRevert(projectTitle) { [weak self] confirmed in
            guard confirmed else { return }

            self?.openProject(url: url, reviewing: false)
        }
    }

    /// The window's close: the review, then the empty project, then `proceed` (the window goes
    /// and the welcome window comes).
    func closeProject(then proceed: @escaping () -> Void) {
        guard canChangeProject else { return }

        reviewProject { [weak self] in
            self?.replaceWithEmpty()
            proceed()
        }
    }

    // MARK: - Recents

    /// The system's recent-documents list (the Dock menu reads it too). Filled in Task 7.
    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: - Errors

    /// The dialog's body for a project error: the spec §7 wording per case, the system's
    /// description otherwise.
    static func describe(_ error: Error) -> String {
        guard let error = error as? ProjectError else {
            return error.localizedDescription
        }

        switch error {
        case .notAPackage:
            return "The file is not a NeuralSheet project."
        case let .unreadable(reason):
            return "The project file could not be read: \(reason)"
        case .newerVersion:
            return "The project was saved by a newer version of NeuralSheet."
        case .missingAudio:
            return "The project's audio file is missing."
        case let .couldNotWrite(reason):
            return reason
        }
    }
}
```

`AudioFileLoader.LoadError` from a package's audio falls to `localizedDescription`; that is acceptable ("The operation couldn't be completed"); if it reads badly in the run, add a `case decode` mapping: "The project's audio file could not be decoded."

- [ ] **Step 6: Split if needed**

`AppModel+Project.swift` will be near 330 lines. If it passes 400 after Task 7, move `// MARK: - Opening` into `AppModel+ProjectOpen.swift`.

- [ ] **Step 7: Build and check by hand**

Build; expected `** BUILD SUCCEEDED **`. Run the app: drop an audio file, transcribe, edit a note. Nothing calls `saveProject` yet from the UI (Task 7 adds the menu), so check the panel from the debugger or wait for Task 7. At minimum the build must be warning-free.

- [ ] **Step 8: Commit**

```bash
git add -A app/NeuralSheet app/Info.plist
git commit -m "app: save, save as, open, revert and close a project

The .neuralsheet type is exported; a package is read and its audio
decoded before the current project is torn down; the standard
save-changes and revert sheets, in AppKit's wording.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: File menu, Open Recent, recents with per-item removal (app + core)

**Files:**
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/GlobalSettings.swift`
- Modify: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/GlobalSettingsTests.swift`
- Create: `app/NeuralSheet/App/RecentProjects.swift`
- Modify: `app/NeuralSheet/App/AppModel+Project.swift` (`noteRecentProject`)
- Modify: `app/NeuralSheet/App/NeuralSheetApp.swift` (`fileMenu`)

**Interfaces:**
- Produces: `GlobalSettings.hiddenRecentProjects: [String]` (paths removed from the list by the user); `@Observable final class RecentProjects` with `init(model:)`, `var urls: [URL]`, `func refresh()`, `func remove(_ url: URL)`, `func clear()`, `func showInFinder(_ url: URL)`; `AppModel.noteRecentProject(_:)` unhides the URL.

- [ ] **Step 1: Write the settings test**

Append to `GlobalSettingsTests.swift`:

```swift
@Test func globalSettingsHiddenRecentProjectsRoundTripAndDefaultEmpty() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("global.settings")

    #expect(GlobalSettings().hiddenRecentProjects.isEmpty)

    var settings = GlobalSettings()
    settings.hiddenRecentProjects = ["/Users/me/Music/Song.neuralsheet"]
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url).hiddenRecentProjects == ["/Users/me/Music/Song.neuralsheet"])
}
```

- [ ] **Step 2: Run to see it fail**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -5`
Expected: compile error, no `hiddenRecentProjects`.

- [ ] **Step 3: Add the field to `GlobalSettings`**

Add after `midiOverflowMode`:

```swift
    /// Recent projects the user removed from the welcome window's list, by path: the system's
    /// recent-documents list has no per-item removal, so the app filters it through this. A
    /// project opened or saved again leaves the list.
    public var hiddenRecentProjects: [String] = []
```

Add `hiddenRecentProjects: [String] = []` as the last `init` parameter and assignment, add `case hiddenRecentProjects` to `CodingKeys`, and in `init(from:)`:

```swift
        hiddenRecentProjects =
            try container.decodeIfPresent([String].self, forKey: .hiddenRecentProjects)
            ?? defaults.hiddenRecentProjects
```

Update the struct's doc comment to mention the hidden recents.

- [ ] **Step 4: Run the tests**

Run: `cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Create `RecentProjects.swift`**

```swift
import AppKit
import Foundation
import Observation

/// The recent projects (projects design §5.7, §6): the system's recent-documents list -- which
/// needs no `NSDocument`, survives relaunches and feeds the Dock menu -- filtered through the
/// paths the user removed from it. Re-read when the menu bar starts being tracked and whenever
/// the welcome window asks.
@MainActor @Observable final class RecentProjects {
    private let model: AppModel
    private(set) var urls: [URL] = []

    @ObservationIgnored private var observer: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        refresh()

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        let hidden = Set(model.settings.hiddenRecentProjects)
        let fresh = NSDocumentController.shared.recentDocumentURLs.filter { !hidden.contains($0.path) }

        if fresh != urls {
            urls = fresh
        }
    }

    /// Remove from Recents: hidden, not forgotten by the system.
    func remove(_ url: URL) {
        if !model.settings.hiddenRecentProjects.contains(url.path) {
            model.settings.hiddenRecentProjects.append(url.path)
        }

        refresh()
    }

    /// Clear Menu: the system's list and the hidden set both.
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        model.settings.hiddenRecentProjects = []
        refresh()
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

- [ ] **Step 6: Make `noteRecentProject` unhide**

In `AppModel+Project.swift`:

```swift
    /// The system's recent-documents list (the Dock menu reads it too); a project the user had
    /// removed from the welcome window's list comes back when it is opened or saved again.
    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        settings.hiddenRecentProjects.removeAll { $0 == url.path }
    }
```

- [ ] **Step 7: The File menu in `NeuralSheetApp.swift`**

Add `@State private var recents: RecentProjects` and in `init`: `_recents = State(initialValue: RecentProjects(model: model))`. Replace `fileMenu(model:)` with:

```swift
    /// The document commands (projects design §5.7). Close is SwiftUI's own ⌘W, which asks the
    /// window's delegate. Export MIDI… only once there is a finished transcription.
    @CommandsBuilder
    private func fileMenu(model: AppModel) -> some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.canChangeProject)

            Button("Open…") { model.openProjectFromPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChangeProject)

            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        model.openProject(url: url)
                    }
                    .help(url.deletingLastPathComponent().path)
                }

                if !recents.urls.isEmpty {
                    Divider()
                }

                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
            .disabled(!model.canChangeProject)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSaveProject)

            Button("Save As…") { model.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canSaveProject)

            Button("Revert to Saved…") { model.revertProject() }
                .disabled(!model.canRevertProject)

            Divider()

            Button("Export MIDI…") { model.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExport)
        }
    }
```

Pass `recents` where the App body calls `fileMenu` (it is a property, so no signature change is needed).

- [ ] **Step 8: Build and check by hand**

Build; expected `** BUILD SUCCEEDED **`. Run: File → Save on an untitled project runs the panel in Music; the title becomes the name and the proxy icon appears; the dot clears; an edit brings it back; ⌘S clears it; Open Recent lists the file; Clear Menu empties it; Revert asks and reloads; Save As… to another name switches the title.

- [ ] **Step 9: Commit**

```bash
git add -A app/NeuralSheet app/Packages/NeuralSheetCore
git commit -m "app: the File menu's project commands and Open Recent

Recents come from the system's list, filtered through the paths the user
removed, so the Dock menu shows them too.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Close veto, quit review, open from the Finder (app)

**Files:**
- Create: `app/NeuralSheet/App/WindowDelegateProxy.swift`
- Modify: `app/NeuralSheet/App/MainWindow.swift` (`attach`, `detach`, `shouldClose`)
- Modify: `app/NeuralSheet/App/AppModel+Project.swift` (`handleWindowClose`)
- Modify: `app/NeuralSheet/App/AppModel.swift` (`pendingOpenURL`)
- Create: `app/NeuralSheet/App/AppDelegate.swift` (moved out of `NeuralSheetApp.swift`)
- Modify: `app/NeuralSheet/App/NeuralSheetApp.swift` (remove `AppDelegate`, set `AppDelegate.model`)
- Modify: `app/NeuralSheet/UI/MainView.swift` (`appear()`: shouldClose, pending open)

**Interfaces:**
- Produces: `WindowDelegateProxy(original:shouldClose:)`; `MainWindowController.shouldClose: ((NSWindow) -> Bool)?`; `AppModel.handleWindowClose(_:) -> Bool`; `AppModel.pendingOpenURL: URL?`; `AppDelegate.model: AppModel?` (static), `application(_:open:)`, `applicationShouldTerminate(_:)`.

- [ ] **Step 1: Create `WindowDelegateProxy.swift`**

```swift
import AppKit

/// Stands in front of the delegate SwiftUI gives its window, answering `windowShouldClose` itself
/// and forwarding every other message to the original (projects design §5.3). SwiftUI's delegate
/// is kept weakly, as the window keeps it; the proxy is installed by `MainWindowController.attach`
/// and taken down by `detach`.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private(set) weak var original: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose(sender)
    }
}
```

If the compiler rejects `nonisolated override` on these two under the MainActor default, mark the whole class `nonisolated` and make `shouldClose` a `@MainActor` closure called through `MainActor.assumeIsolated` inside `windowShouldClose`.

- [ ] **Step 2: Edit `MainWindowController`**

Add:

```swift
    /// The close question, installed by the main view: true lets the window go.
    @ObservationIgnored var shouldClose: ((NSWindow) -> Bool)?

    @ObservationIgnored private var delegateProxy: WindowDelegateProxy?
```

In `attach`, after `self.window = window`, add `installCloseVeto(on: window)`. Add:

```swift
    /// SwiftUI owns the delegate; the proxy answers the close alone. Re-asserted on every attach,
    /// since SwiftUI may replace the delegate when the scene updates.
    private func installCloseVeto(on window: NSWindow) {
        guard !(window.delegate is WindowDelegateProxy) else { return }

        let proxy = WindowDelegateProxy(original: window.delegate) { [weak self] window in
            self?.shouldClose?(window) ?? true
        }

        window.delegate = proxy
        delegateProxy = proxy
    }

    func detach() {
        if let window, let delegateProxy, window.delegate === delegateProxy {
            window.delegate = delegateProxy.original
        }

        delegateProxy = nil
        window = nil
    }
```

(Replace the existing `detach`.)

- [ ] **Step 3: `handleWindowClose` and `pendingOpenURL`**

In `AppModel.swift`, in the `// MARK: - Project` block:

```swift
    /// A file the Finder asked to open before a window could show an error for it; the main
    /// view opens it once the dialogs are installed.
    @ObservationIgnored var pendingOpenURL: URL?
```

In `AppModel+Project.swift`, under `// MARK: - Revert and close`:

```swift
    /// The window's close button and ⌘W: refused with a beep while recording or transcribing;
    /// otherwise the review runs, and the window is closed for real a turn later with the project
    /// already cleared and the welcome window up. Always false: `NSWindow.close()` does not ask
    /// again, so the window goes exactly once.
    func handleWindowClose(_ window: NSWindow) -> Bool {
        guard canChangeProject else {
            NSSound.beep()
            return false
        }

        closeProject { [weak self] in
            self?.showWelcomeWindow?()

            DispatchQueue.main.async {
                window.close()
            }
        }

        return false
    }
```

- [ ] **Step 4: Create `AppDelegate.swift` and remove the class from `NeuralSheetApp.swift`**

```swift
import AppKit

/// Quit and the Finder (projects design §5.4, §5.5). The model is handed over by the app's
/// `init`, before any delegate method can run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    /// The standalone quits with its last window, as the JUCE one did: closing the welcome
    /// window quits; closing the project window opens the welcome window first, so it is never
    /// the last.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q: the save-changes review when the project is edited, with the answer delivered later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.computeProjectEdited() else { return .terminateNow }

        model.reviewProject(then: {
            NSApp.reply(toApplicationShouldTerminate: true)
        }, cancelled: {
            NSApp.reply(toApplicationShouldTerminate: false)
        })

        return .terminateLater
    }

    /// A double-click on a `.neuralsheet` in the Finder, or a drop on the Dock icon. Opened at
    /// once when a window can show a failure; parked on the model until then (a launch by
    /// double-click), for the main view to pick up.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model,
            let url = urls.first(where: { $0.pathExtension.lowercased() == "neuralsheet" })
        else { return }

        if let show = model.showProjectWindow, model.presentError != nil {
            model.openProject(url: url)
            show()
        } else {
            model.pendingOpenURL = url
            model.showProjectWindow?()
        }
    }
}
```

In `NeuralSheetApp.init`, after `let model = AppModel()`: `AppDelegate.model = model`. Delete the `AppDelegate` class at the bottom of `NeuralSheetApp.swift`.

- [ ] **Step 5: Wire the main view**

In `MainView.appear()`, after `Dialogs.installProjectDialogs(...)`:

```swift
        windowController.shouldClose = { window in model.handleWindowClose(window) }

        if let url = model.pendingOpenURL {
            model.pendingOpenURL = nil
            model.openProject(url: url)
        }
```

- [ ] **Step 6: Build and check by hand**

Build; expected `** BUILD SUCCEEDED **`. Run: ⌘W with changes shows the sheet; Cancel keeps the window; Don't Save closes it (the app quits for now, since the welcome window is Task 9); ⌘Q with changes shows the sheet and Cancel keeps the app running; ⌘W during a transcription beeps; double-clicking a saved `.neuralsheet` in the Finder opens it (after a build, `open -a` the built app once so Launch Services registers the type).

- [ ] **Step 7: Commit**

```bash
git add -A app/NeuralSheet
git commit -m "app: the window refuses to close over unsaved changes; quit and the Finder

A delegate proxy in front of SwiftUI's answers windowShouldClose alone;
the app delegate reviews on quit and opens .neuralsheet files.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The welcome window (ui)

**Files:**
- Create: `app/NeuralSheet/UI/Welcome/WelcomeView.swift`
- Create: `app/NeuralSheet/UI/Welcome/RecentProjectsList.swift`
- Modify: `app/NeuralSheet/App/NeuralSheetApp.swift` (the welcome scene, first in the body)
- Modify: `app/NeuralSheet/UI/MainView.swift` (`appear()`: install the window closures)

**Interfaces:**
- Consumes: `RecentProjects` (Task 7), `AppModel.newProject()`, `openProjectFromPanel()`, `openProject(url:)`, `showProjectWindow`, `showWelcomeWindow`, `pendingOpenURL`.
- Produces: `WelcomeView(model:recents:)`, `RecentProjectsList(recents:open:)`.

- [ ] **Step 1: The scene**

In `NeuralSheetApp.body`, before the main `Window`, add:

```swift
        // First, so it is the window SwiftUI opens at launch; the project window opens from it.
        Window("Welcome to NeuralSheet", id: "welcome") {
            WelcomeView(model: model, recents: recents)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
```

- [ ] **Step 2: Create `WelcomeView.swift`**

```swift
import AppKit
import SwiftUI

/// The window shown at launch and after the project window closes (projects design §6): the
/// app's icon, name and version with Create and Open on the left, the recent projects on the
/// right. In the app's own theme.
struct WelcomeView: View {
    let model: AppModel
    let recents: RecentProjects

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    static let size = CGSize(width: 800, height: 460)
    private static let leftWidth: CGFloat = 440

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: Self.leftWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.bgPanel)

            Rectangle()
                .fill(Theme.divStrong)
                .frame(width: 1)

            RecentProjectsList(recents: recents) { url in
                open(url)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgSidebar)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.bgRoot)
        .onAppear(perform: appear)
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("NeuralSheet")
                .font(Fonts.sans(28, weight: 600))
                .foregroundStyle(Theme.textBright)
                .padding(.top, 14)

            Text("Version \(Self.version)")
                .font(Fonts.sans(12, weight: 400))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                WelcomeAction(title: "Create New Project", symbol: "plus.square") {
                    model.newProject()
                    showProject()
                }

                WelcomeAction(title: "Open Existing Project…", symbol: "folder") {
                    model.openProjectFromPanel()

                    if model.projectURL != nil {
                        showProject()
                    }
                }
            }
            .padding(.top, 36)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        return "\(short) (\(build))"
    }

    // MARK: - Actions

    /// The welcome window is only up while no project is open, so a URL that became the
    /// project is an open that succeeded; a failure showed its dialog and left it untitled.
    private func open(_ url: URL) {
        model.openProject(url: url)

        if model.projectURL == url {
            showProject()
        }
    }

    private func showProject() {
        openWindow(id: "main")
        dismissWindow(id: "welcome")
    }

    /// The model's window closures, and a file the Finder asked for before any window was up.
    private func appear() {
        recents.refresh()

        model.showProjectWindow = { [openWindow, dismissWindow] in
            openWindow(id: "main")
            dismissWindow(id: "welcome")
        }
        model.showWelcomeWindow = { [openWindow] in
            openWindow(id: "welcome")
        }

        if model.pendingOpenURL != nil {
            showProject()
        }
    }
}

/// One of the two rows on the left: an SF Symbol and a label, lit on hover.
private struct WelcomeAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)

                Text(title)
                    .font(Fonts.sans(14, weight: 500))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.bgControlActive : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 3: Create `RecentProjectsList.swift`**

```swift
import AppKit
import SwiftUI

/// The right pane of the welcome window: the recent projects, most recent first, with a
/// double-click or Return to open, and a right-click for Show in Finder and Remove from Recents.
struct RecentProjectsList: View {
    let recents: RecentProjects
    let open: (URL) -> Void

    @State private var selection: URL?

    var body: some View {
        if recents.urls.isEmpty {
            Text("No Recent Projects")
                .font(Fonts.sans(13, weight: 400))
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(recents.urls, id: \.self, selection: $selection) { url in
                row(url)
                    .tag(url)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Show in Finder") { recents.showInFinder(url) }
                        Button("Remove from Recents") { recents.remove(url) }
                    }
                    .onTapGesture(count: 2) { open(url) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                guard let selection else { return .ignored }

                open(selection)
                return .handled
            }
        }
    }

    private func row(_ url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)

        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .package))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Fonts.sans(13, weight: 500))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(Self.abbreviated(url.deletingLastPathComponent().path))
                    .font(Fonts.sans(11, weight: 400))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .opacity(exists ? 1 : 0.5)
    }

    /// `/Users/me/Music` → `~/Music`.
    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
```

- [ ] **Step 4: Install the closures from the main view too**

In `MainView`, add `@Environment(\.openWindow) private var openWindow` and `@Environment(\.dismissWindow) private var dismissWindow`; in `appear()`, before the pending-open block:

```swift
        model.showProjectWindow = { [openWindow, dismissWindow] in
            openWindow(id: "main")
            dismissWindow(id: "welcome")
        }
        model.showWelcomeWindow = { [openWindow] in
            openWindow(id: "welcome")
        }
```

- [ ] **Step 5: Build and check by hand**

Build; expected `** BUILD SUCCEEDED **`, warning-free. Run: the welcome window appears alone at launch; Create New Project opens the project window and dismisses the welcome; ⌘W on a clean project returns to the welcome window; on an edited one the sheet shows first; a double-click on a recent opens it; Remove from Recents hides it and opening it again brings it back; Show in Finder selects it; closing the welcome window quits; double-clicking a `.neuralsheet` in the Finder with the app closed lands on the project window without the welcome; Escape and Space in the welcome window do nothing to the transport.

If SwiftUI's `Window` scene refuses `hiddenTitleBar` with a fixed size, drop the style and keep the fixed size.

- [ ] **Step 6: Commit**

```bash
git add -A app/NeuralSheet
git commit -m "ui: the welcome window

Shown at launch and after the project window closes: create, open, the
recent projects with Show in Finder and Remove from Recents; closing it
quits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Docs (docs)

**Files:**
- Modify: `AGENTS.md` (the deliberate departures list; `UI/Welcome/` in "Where things are")
- Modify: `CHANGELOG.md` (Unreleased: Added, Changed, Removed)
- Modify: `docs/design/2026-09-21-projects-design.md` (§9 cross-checked against the code)

- [ ] **Step 1: AGENTS.md**

In the "Where things are" tree, under `NeuralSheet/UI/`, add `the welcome window,` to the list of things the UI folder holds. In the "inventory is the reference" rule, replace `the session stores the transcription;` with:

```
a project is a `.neuralsheet` package holding the audio, the transcription and the settings, with New / Open / Open Recent / Save / Save As / Revert / Close and the save prompt on close and quit, the dirty dot and the proxy icon in the title, and no autosaved session (design: `docs/design/2026-09-21-projects-design.md`); a welcome window at launch and after the project window closes;
```

- [ ] **Step 2: CHANGELOG.md**

Under `## [Unreleased]` → `### Added`, append:

```
- Projects: a `.neuralsheet` package that holds the audio, the transcription, the edits, the mix and the editor settings, with New, Open, Open Recent, Save, Save As, Revert to Saved and Close, the save prompt on close and quit, the dirty dot and the proxy icon in the window title, and double-click from the Finder.
- A welcome window at launch and after the project window closes: create a project, open one, or pick a recent one.
```

Under `### Changed`, append:

```
- The window is titled after the project rather than "NeuralSheet".
```

Add a `### Removed` section after `### Changed`:

```
### Removed

- The autosaved session under `~/Library/NeuralSheet`: the app opens on the welcome window rather than on the last take, and a project file is where work is kept. The two session files and any leftover recording are deleted at launch.
```

- [ ] **Step 3: Cross-check the design's §9 and §8 against what was built**

Read `docs/design/2026-09-21-projects-design.md` §8 (files) and §9 (departures) and correct any file name or behaviour that ended up different (for example if `AppModel+ProjectOpen.swift` was split out in Task 6, or the welcome window's title bar style changed).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md CHANGELOG.md docs/design/2026-09-21-projects-design.md
git commit -m "docs: projects in the departures list, the changelog and the design

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
