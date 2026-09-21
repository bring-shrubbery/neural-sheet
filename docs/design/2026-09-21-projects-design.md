# Projects — Design

NeuralSheet keeps one autosaved session under `~/Library/NeuralSheet`: a small JSON, the
transcription beside it, and the take referenced by path. This replaces that with **projects**: a
self-contained `.neuralsheet` package the user names and saves where they like, the standard Mac
file lifecycle around it (New, Open, Open Recent, Save, Save As, Revert, Close, Quit with the
save prompt, the dirty dot, the title with proxy icon, double-click from the Finder), and an
Xcode-style **welcome window** at launch that creates a project or opens a recent one.

Where it departs from the NeuralNote inventory (`2026-09-17-neuralnote-feature-inventory.md`) it
says so in §9; everything it does not mention is unchanged. It builds on the editor design
(`2026-09-19-midi-editor-design.md`), whose §8.1 session it supersedes.

## 1. Goals and non-goals

Goals

- A project file that holds everything: the audio, the model's output, the edited notes, the mix
  and the editor settings. Copying the file to another Mac opens the same project.
- The standard document lifecycle a Mac user expects from a non-autosaving app, with the system's
  own wording and button order, and the window refusing to close over unsaved changes.
- A welcome window at launch and after the last project closes: create, open, recents.
- Every rule of the file format lives in `NeuralSheetCore` behind `swift test`; the app layer only
  moves state in and out of the model.

Non-goals

- More than one project open at a time. The app owns one audio engine and one `AppModel`; a
  second window would need a second model sharing the engine. Opening another project replaces
  the current one, after the save prompt, as Logic and GarageBand do.
- `NSDocument`. Its extra features (Duplicate, Rename, Move To, autosave in place, Versions) each
  assume a second document can exist, which conflicts with the point above; adopting it would mean
  rehosting the main window and constraining the document controller everywhere. The lifecycle is
  hand-rolled on `AppModel`.
- Autosave of an unsaved project. An untitled project that is never saved dies with the process,
  as in TextEdit before autosave.
- A custom document icon in the Finder.
- Backwards compatibility with the Library session. The two files are deleted at launch.

## 2. Decisions

| Topic | Decision |
|---|---|
| Documents | One at a time; every way of opening or creating a project reviews and replaces the current one |
| On disk | A package (`Name.neuralsheet`, a folder the Finder shows as one file): `project.json`, `transcription.json`, `audio/<file>` |
| Audio in the file | The dropped file copied byte for byte, or the take's native-rate WAV; never re-encoded |
| Writing | The whole package is built in a temporary directory and swapped into place atomically |
| Dirty rule | Content only: audio, transcription, mix, instrument selection, tempo, grid, snap, target instrument. Tab, playhead, follow, zoom and note selection are saved but never dirty the project |
| Dirty detection | A snapshot of the content compared to the one last saved, so undoing back to the saved state clears the dot |
| Lifecycle | Hand-rolled on `AppModel` (`AppModel+Project.swift`); the window's `isDocumentEdited`, `representedURL` and title follow the model; a delegate proxy answers `windowShouldClose` |
| Recents | `NSDocumentController.shared`'s recent-documents list, which needs no `NSDocument` and feeds the Dock menu |
| Welcome | A second SwiftUI `Window` scene, fixed size, in the app's own theme; shown at launch and when the project window closes; closing it quits |
| New project | Untitled at once; the save panel on the first Save or the first close with changes |
| Library session | Removed. `session.json` and `transcription.json` are deleted at launch and the recordings folder is swept |
| Overflow mode | Stays a global setting; the project file does not carry a copy |

## 3. The package (`NeuralSheetCore`)

### 3.1 Layout

```
Name.neuralsheet/
  project.json          ProjectState
  transcription.json    ProjectTranscription, absent without a finished transcription
  audio/<file>          the audio, named in project.json
```

The type is exported from the app's Info.plist as `com.quassum.neuralsheet.project`, conforming
to `com.apple.package`, extension `neuralsheet`, with the app as its editor. `LSTypeIsPackage`
makes the Finder show the folder as a file; the app is not sandboxed, so opening a file from the
Finder needs no bookmark.

### 3.2 `ProjectState` (was `SessionState`)

```swift
public struct ProjectState: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public var formatVersion = ProjectState.currentFormatVersion
    /// The audio's file name inside `audio/`; empty when the project has no audio.
    public var audioFileName = ""
    /// What the toolbar shows and the MIDI export is named after; nil for a recording.
    public var audioDisplayName: String? = nil
    public var selectedGroups: [Int32] = []
    public var mixer: [Int: InstrumentChannelSettings] = [:]
    public var exportTempo: Double = 120
    public var gridOffsetSeconds: Double = 0
    public var gridDivision: GridDivision = .sixteenth
    public var snapEnabled = true
    public var targetProgram: Int? = nil
    // View state: saved, never dirty.
    public var workspace: Workspace = .transcribe
    public var playheadSeconds: Double = 0
    public var playheadCentered = true
    public var zoomLevel: Double = 1
    public var verticalZoom: Double = -1
}
```

Decoding is tolerant as today: every key falls back to its default so a file from an older
version opens, and it is written with sorted keys and indentation so two saves of the same state
give the same bytes. `formatVersion` is the one exception: a file whose version is greater than
`currentFormatVersion` refuses to open with `ProjectError.newerVersion`, since a newer app may
have written something this one would silently drop on the next save. `sourceAudioPath`,
`midiOverflowMode` and the embedded `transcription` go; nothing reads a Library session any more.

### 3.3 `ProjectTranscription` (was `SessionTranscription`)

Unchanged in content: `sourceSampleCount`, `rawNotes`, `document`. Written compact. The sample
count still guards the notes: a package whose audio decodes to another length gets no notes
rather than notes against the wrong audio.

### 3.4 `ProjectContent`

The value the dirty rule compares, built by the app from the model and kept beside the last save:

```swift
public struct ProjectContent: Equatable, Sendable {
    public var transcription: ProjectTranscription?
    public var selectedGroups: [Int32]
    public var mixer: [Int: InstrumentChannelSettings]
    public var exportTempo: Double
    public var gridOffsetSeconds: Double
    public var gridDivision: GridDivision
    public var snapEnabled: Bool
    public var targetProgram: Int?
}
```

The audio's identity is not in it (a `SourceAudio` is the app's type, and holding one weakly
turned out to be the wrong idea, §4.1); the app compares a generation counter instead (§5.2).

### 3.5 `ProjectPackage`

```swift
public enum ProjectError: Error, Equatable {
    case notFound, notAPackage, unreadable(String), newerVersion(Int), missingAudio
    case couldNotWrite(String)
}

public struct ProjectPackage: Sendable {
    public var state: ProjectState
    public var transcription: ProjectTranscription?

    /// Reads the two JSON files; `audioURL` is where the audio is, checked to exist.
    public static func read(from url: URL) throws -> (package: ProjectPackage, audioURL: URL?)

    /// Writes the package to `url`, replacing whatever is there. `audioSource` is copied to
    /// `audio/<state.audioFileName>`; nil writes no audio (and `audioFileName` must be empty).
    public func write(to url: URL, audioSource: URL?) throws
}
```

`write` builds `Name.neuralsheet` in a temporary directory beside the destination (same volume,
so the copy is an APFS clone and the swap is a rename), copies the audio, writes both JSON files,
then `FileManager.replaceItemAt(_:withItemAt:)` swaps it in. A failure at any step leaves the
destination as it was and throws `couldNotWrite` with the underlying description. `audioSource`
may be inside the destination package itself (the unchanged-audio case): the copy is made before
the swap, so that works.

`read` accepts a URL whose extension is `neuralsheet` and which is a directory holding
`project.json`. A URL with nothing at it at all is `notFound` ("The project file could not be
found.") -- a recent whose project has been deleted or moved away, which must not be told it is not
a NeuralSheet project; anything else is `notAPackage`. A `project.json` that does not decode is
`unreadable`. A missing `transcription.json` is nil, an unreadable one is nil too (the audio and
settings survive, as the session did). An `audioFileName` whose file is not there is
`missingAudio`; an empty `audioFileName` is a project without audio, `audioURL` nil.

## 4. Lifecycle (`AppModel+Project.swift`)

### 4.1 State

```swift
/// Where the project is saved, or nil for an untitled one.
private(set) var projectURL: URL?
/// The window title: the file's display name, or "Untitled".
var projectTitle: String
/// Content differs from what was last saved (or, untitled, from empty).
var isProjectEdited: Bool
/// New, Open, Open Recent, Revert and Close: not while recording or transcribing.
var canChangeProject: Bool { state != .recording && state != .processing }
/// Save and Save As: not while recording. A save mid-transcription writes the audio and the
/// settings without the notes, which is what the quit review needs (§4.3).
var canSaveProject: Bool { state != .recording }
var canRevertProject: Bool { canChangeProject && projectURL != nil && isProjectEdited }
```

The audio's identity is not a weak reference to the source: the engine retires a source's boxes
on a grace period, so a `weak var lastSavedSource: SourceAudio?` went nil nondeterministically and
a clean project read as "audio removed". Instead `AppModel` has `sourceGeneration`, bumped on
every assignment to `source`, and `lastSavedSourceGeneration`; the dirty rule is
`sourceGeneration != lastSavedSourceGeneration || projectContent() != lastSavedContent`.
Internally: `lastSavedContent: ProjectContent`, `lastSavedSourceGeneration: Int`, and
`lastSavedAudioFileName`. `AppModel.init` ends with `markProjectSaved(audioFileName: "")`, so a
fresh project is clean and the first drop dirties it.

### 4.2 Commands (the views' and menus' contract)

| Command | Behaviour |
|---|---|
| `newProject()` | `reviewProject` then `replaceWithEmpty()`: `clearNow()`, selection to Automatic, tempo and grid to defaults, mixer settings dropped, `projectURL = nil`, saved snapshot = empty |
| `openProject(url:)` | `ProjectPackage.read`, then `AudioFileLoader.load` on the audio, *before* anything is torn down; a failure shows "Could not open the project." with the reason and leaves the current project alone. Then `reviewProject`, `replaceWithEmpty()`, install the source, the settings and the view state, `projectURL = url`, recents noted. The notes are installed, and the project marked saved, only when they can be trusted (below); `read` also reports `transcriptionUnreadable`, a `transcription.json` that exists but did not decode |
| `openProjectFromPanel()` | `NSOpenPanel` limited to the package type, then `openProject(url:)` |
| `saveProject()` | Untitled: `saveProjectAs()`. Else write to `projectURL` |
| `saveProjectAs()` | `NSSavePanel` beside the current file, or in the Music folder for an untitled project; `nameFieldStringValue` the current title (`Untitled` becomes the audio's display name when there is one), the package type only; then write and adopt the URL |
| `revertProject()` | The standard question ("Do you want to revert to the most recently saved version of “X”?" / "Your current changes will be lost." Revert / Cancel); on Revert, `openProject(url:)` without the review |
| `closeProject(then:)` | `reviewProject`, then `replaceWithEmpty()` and the completion (the window's close proceeds and the welcome window opens) |
| `reviewProject(then:)` | Nothing to do when clean. Else the sheet "Do you want to save the changes made to the document “X”?" / "Your changes will be lost if you don't save them." with Save (default), Cancel, Don't Save. Save runs `saveProject()` (which may run the save panel) and continues only if it succeeded; Cancel stops; Don't Save continues. With unsaved changes and no `presentSaveReview` installed, that is a wiring bug: an `assertionFailure` in debug, then it proceeds rather than losing the work silently |

Notes that cannot be installed (`transcriptionUnreadable`, or the audio's sample count does not
match the transcription's) are dropped: `installProject` leaves the baseline from
`replaceWithEmpty()` standing rather than calling `markProjectSaved`, so the project reads edited,
the dot shows, and Close (or the next Save) asks rather than silently overwriting the file with
the notes gone. It also shows "Could not load the project's transcription." / "The notes in the
file do not match its audio, or could not be read, and were left out. Saving the project will
remove them from the file." (§7).

The write: `ProjectContent` and `ProjectState` are taken from the model; `audioSource` is the
package's own `audio/<name>` when `sourceGeneration` has not changed since the last save and the
project has a URL, else `source.sourcePath`. A recording's file name in the package is
`recording.wav`; a dropped file keeps its name. A failed write shows "Could not save the
project." with the reason and the project stays edited. After a successful write the snapshot is
retaken, the URL adopted, and the URL noted in the recents.

A package moved or renamed in the Finder while it is open is not followed: the audio that was to be
cloned out of it is gone, so the save falls back to the take's own original path, and only when
that is gone too does it fail with "The project's audio file is no longer where it was saved."
Following the package (an `NSFilePresenter` that updates `projectURL` on a rename) is a follow-up.

The Library copy of a take is not deleted by a save: it goes when the project is cleared, as
today (`deleteRecordedFiles`), and every path out of a project runs through `clearNow()`. A take
left behind by a crash is swept at the next launch (§4.5).

### 4.3 While recording or transcribing

New, Open, Open Recent, Revert and Close are disabled in the menus and the welcome window's
actions are unreachable (the welcome window is not up while a project is). Save and Save As stay
enabled while transcribing, so the quit review below has a way to save; they disable only while
recording, since a take in progress has no file to copy yet. The close button refuses
(`windowShouldClose` false, with a beep). Quit is allowed: the review saves what is saveable (with
a run in flight, the audio and settings without the transcription; while recording there is
nothing new to save, since a take only starts from empty) and the process ends.

### 4.4 The existing questions

The discard-edits confirmations before loading another file, clearing and re-transcribing
(editor design §3.5) stay: they protect edits within the project, which the save prompt does not.

### 4.5 Launch

At launch the model deletes `~/Library/NeuralSheet/session.json` and `transcription.json` if
present and removes every file in the recordings folder: nothing references a Library recording
any more, so anything there is a crash's leftover. `AppPaths` loses `session` and
`transcription`. `Persistence.restoreOnce()` and the session half of `Persistence` go; the
settings half stays, and a `ProjectTracker` takes the session's place (§5.2).

## 5. Window and app

### 5.1 Title, proxy icon, dirty dot

The title is SwiftUI's own: `MainView` carries `.navigationTitle(model.projectTitle)`, so
`window.title` follows it directly. `MainWindowController` gets `setDocument(url:edited:)`,
called from an observation the tracker below drives: it sets `window.representedURL` (the proxy
icon and its Finder menu) and `window.isDocumentEdited` (the dot). The `Window` scene's own title
stays "NeuralSheet" as the fallback before `navigationTitle` has taken over.

### 5.2 `ProjectTracker`

Replaces the session half of `Persistence`. Two observation loops, each re-armed after it fires:
one reads `model.projectContent()` and `model.sourceGeneration` (not the source itself, §4.1) and,
100 ms after the last change to either, recomputes `computeProjectEdited()` into
`model.isProjectEdited` (a few thousand note structs at most, and only after a change, never per
frame); the other reads `model.projectURL` and `model.isProjectEdited` and pushes them to the
window through `setDocument(url:edited:)` at once, undebounced. `Persistence` keeps the settings
observation and the terminate hook (settings write, MIDI scratch removal); the session save on
terminate goes.

### 5.3 Vetoing the close

SwiftUI sets the window's delegate itself, so `MainWindowController.attach` installs a
`WindowDelegateProxy`: an `NSObject` that keeps the original delegate weakly, forwards every
selector to it (`responds(to:)` and `forwardingTarget(for:)`), and implements `windowShouldClose`
alone by calling a `shouldClose` closure the controller was handed (`MainView.appear()` sets it
to `model.handleWindowClose`):

- `canChangeProject` false: beep, return false.
- Otherwise `model.closeProject` runs the review; once it proceeds, `showWelcomeWindow?()` shows
  the welcome window and `window.close()` runs a moment later on the main queue (so the close
  finishes outside this call), and `windowShouldClose` itself always returns false:
  `NSWindow.close()` does not ask the delegate again, so the window goes exactly once.

`detach` restores the original delegate. The proxy is re-asserted on every `attach`, since SwiftUI
may replace the delegate when the scene updates.

### 5.4 Quit

`AppDelegate.applicationShouldTerminate` returns `.terminateNow` when the project is clean, else
runs `model.reviewProject` and returns `.terminateLater`, replying with
`NSApp.reply(toApplicationShouldTerminate:)` from the completion (true) or the cancel (false).
`applicationShouldTerminateAfterLastWindowClosed` stays true: closing the welcome window, the last
one, quits; closing the project window opens the welcome window first, so it is never the last.

### 5.5 Opening from the Finder

`AppDelegate.application(_:open:)` takes the first `.neuralsheet` URL. When a window is already
up and ready (`model.showProjectWindow` and `model.presentError` are both installed, meaning a
project or welcome window has appeared), it opens at once and shows the project window.
Otherwise the URL is parked on `model.pendingOpenURL` and `model.showProjectWindow?()` is called
if it exists yet, to bring a window up; nothing here opens the project itself in that case.
`pendingOpenURL` is consumed by `MainView.appear()`, once the dialogs are installed, which clears
it and calls `model.openProject(url:)`; the welcome view's `appear()` only notices a parked URL to
open the project window and dismiss itself (§6), it does not open the project. Audio files are
not accepted this way; they are dropped on the project window as today.

### 5.6 Windows

Both scenes are `Window`s. The welcome scene comes first in the `App` body so it is the one
SwiftUI opens at launch; the main scene opens through `openWindow(id: "main")` and carries
`.restorationBehavior(.disabled)`, so a relaunch never restores the project window beside the
welcome one (the welcome window is what a launch shows, and the project window opens from it,
never from restoration). The welcome view captures `openWindow` and `dismissWindow` into closures
the model calls (`model.showProjectWindow`, `model.showWelcomeWindow`), the way `presentError` is
installed today.

On a cold launch nothing has installed `model.presentError` yet, so the welcome view's `appear()`
installs a windowless one (`Dialogs.install(on: model) { nil }`), which shows an app-modal alert
rather than a sheet, the right form before any project window exists. A failed open chosen from
the welcome window still shows its dialog this way. `MainView.appear()` installs its own, sheeted
version once the project window exists, in place of the welcome one.

### 5.7 File menu

```
New Project           ⌘N
Open…                 ⌘O
Open Recent          ▸  (the recents, a separator, Clear Menu)
──
Close                 ⌘W   (SwiftUI's own)
Save                  ⌘S
Save As…              ⌘⇧S
Revert to Saved…
──
Export MIDI…          ⌘⇧E
```

`CommandGroup(replacing: .newItem)` and `CommandGroup(replacing: .saveItem)`; Open Recent is a
`Menu` built from `NSDocumentController.shared.recentDocumentURLs` (re-read when the menu bar
starts tracking, as the Audio menu does its devices), each item the file's display name, its
folder in the tooltip. `noteNewRecentDocumentURL` after every open and save,
`clearRecentDocuments` from Clear Menu. "Save As…" is the right name for an app without autosave
in place ("Duplicate" is the autosaving variant).

## 6. Welcome window (`UI/Welcome/`)

A `Window("Welcome to NeuralSheet", id: "welcome")`, 800 × 460 content, `.windowResizability
(.contentSize)`, hidden title bar, `Theme.bgRoot` background, the app's fonts.

Left pane (440 px, `Theme.bgPanel`): the app icon (`NSApp.applicationIconImage`, 128 px) centred
near the top, "NeuralSheet" in `Fonts` title weight, "Version 1.0.0 (123)" from the bundle in
`Theme.textMuted`; under them two rows, left-aligned, each an icon and a label in
`Theme.textPrimary`, highlighted on hover like the toolbar buttons:

- **Create New Project** — `model.newProject()` (nothing to review: no project is open), show the
  project window, dismiss the welcome.
- **Open Existing Project…** — `model.openProjectFromPanel()`; on success the same.

Right pane (`Theme.bgSidebar`): the recents, most recent first, each row the package's display
name in `Theme.textPrimary` over its folder path (home abbreviated with `~`) in
`Theme.textFaint`, with the generic package icon. A SwiftUI `List` with
`contextMenu(forSelectionType:menu:primaryAction:)` gives this for free: single click selects,
double-click or Return (the list's own primary action) opens, right-click offers the menu
(**Show in Finder** and **Remove from Recents**); there is no separate key handler. The recents
list has no per-item removal, so **Remove from Recents** works through
`GlobalSettings.hiddenRecentProjects`, a small array of paths kept in the settings that the list
is filtered through; Clear Menu empties both it and the system's own recent-documents list, and a
project opened or saved again is taken back out of it. A file that no longer exists is shown
dimmed and opens "Could not open the project." with the reason. Empty state: "No Recent Projects"
centred in `Theme.textFaint`.

Shown at launch (unless a file is being opened), and by the project window's close. Closing it
quits (§5.4). The keyboard shortcuts installer stays bound to the project window, so nothing of
the transport reacts in the welcome window.

## 7. Strings

All new; NeuralNote had no projects. The document sheets use AppKit's exact wording so they read
like every other app's:

| Where | Text |
|---|---|
| Review | "Do you want to save the changes made to the document “X”?" / "Your changes will be lost if you don't save them." Save · Cancel · Don't Save |
| Revert | "Do you want to revert to the most recently saved version of “X”?" / "Your current changes will be lost." Revert · Cancel |
| Open failure | "Could not open the project." / the reason ("The project file could not be found.", "The file is not a NeuralSheet project.", "The project's audio file is missing.", "The project's audio file could not be decoded.", "The project was saved by a newer version of NeuralSheet.", or the system's description) |
| Notes dropped | "Could not load the project's transcription." / "The notes in the file do not match its audio, or could not be read, and were left out. Saving the project will remove them from the file." |
| Save failure | "Could not save the project." / the reason ("The project's audio file is no longer where it was saved.", "The audio has no file to copy.", or the system's description) |
| Save panel | title "Save Project", the package type |
| Open panel | title "Open Project" |

## 8. Files

NeuralSheetCore

- `ProjectState.swift` (from `SessionState.swift`), `ProjectTranscription.swift`,
  `ProjectContent.swift`, `ProjectPackage.swift`; `AppPaths` minus the two session URLs.
- Tests: `ProjectStateTests` (from `SessionStateTests`), `ProjectContentTests`,
  `ProjectPackageTests`, `AppPathsTests`, and a `hiddenRecentProjects` round-trip test in
  `GlobalSettingsTests`.

App

- `App/AppModel+Project.swift`: §4, apart from opening. `App/AppModel+ProjectOpen.swift`: opening
  a project (split out to keep both files under the 400-line rule). `App/ProjectTracker.swift`:
  §5.2. `App/Persistence.swift` keeps only the settings (moved out of `AppModel+Session.swift`,
  which goes).
- `App/MainWindow.swift`: the represented URL and the dot (the title is SwiftUI's own,
  `navigationTitle`, §5.1), the delegate proxy (`App/WindowDelegateProxy.swift`).
- `App/NeuralSheetApp.swift`: the welcome scene, the File menu, the Open Recent menu.
  `AppDelegate` moves to `App/AppDelegate.swift`: quit review, open files.
- `App/Dialogs.swift`: the three-button review and the revert question, and the windowless
  install the welcome window uses before any project window exists (§5.6).
- `App/ProjectType.swift`: `UTType.neuralSheetProject`.
- `UI/Welcome/WelcomeView.swift`, `UI/Welcome/RecentProjectsList.swift`, `App/RecentProjects.swift`
  (the document controller wrapper and the hidden set).
- `app/Info.plist`: the exported type and the document type.

## 9. Departures from the inventory

- The session (§8) is gone: no `session.json`, no restore at launch, no `recordings` folder kept
  between launches. A project file holds what the session held, and the audio with it.
- A welcome window at launch, which NeuralNote never had; the app no longer opens straight onto
  an empty main window.
- The window's title is the project's name rather than "NeuralSheet", with the proxy icon and
  the dirty dot; the toolbar still shows the audio file's name as inventory §1.6 has it.

## 10. Testing

`swift test` in NeuralSheetCore:

- `ProjectState`: defaults, round trip with sorted keys, missing keys fall back, a greater
  `formatVersion` throws `newerVersion`.
- `ProjectPackage.write`: a round trip with a stand-in audio file and a transcription; without a
  transcription the file is absent; writing over an existing package replaces it; writing where
  the audio copy fails (a missing source) throws and leaves the previous package untouched;
  `audioSource` inside the destination package works.
- `ProjectPackage.read`: not a package, unreadable JSON, missing audio, no audio at all,
  unreadable transcription gives nil with the rest intact.
- `ProjectContent`: equal for equal state, unequal per field.

In the app, by building and running: the dirty dot after a drop, an edit, a fader move, and its
clearing on undo back to saved; ⌘W with changes shows the sheet and Cancel keeps the window;
Don't Save opens the welcome; Save on untitled runs the panel; ⌘Q with changes reviews; a
double-click on a `.neuralsheet` in the Finder opens it; the recents update; Revert asks and
reloads; a project with its audio deleted refuses to open with the reason.

## 11. Implementation order

1. Core: `ProjectState`, `ProjectTranscription`, `ProjectContent`, `ProjectPackage`, tests.
2. App: `AppPaths` and `Persistence` trimmed, launch cleanup, `AppModel+Project` with the
   content snapshot and the edited flag, `ProjectTracker`.
3. Window: title, proxy icon, dot, the delegate proxy, the review and revert sheets.
4. Menus, save and open panels, recents, the Info.plist types, the app delegate's quit and open.
5. The welcome window and the scene choreography.
6. Docs: AGENTS.md departures, the changelog, this design's §9 cross-checked against the code.
