# Key detection and scale highlight — Design

The roll knows nothing about key: every lane looks the same, a wrong note is not visibly wrong,
and the MusicXML export writes C major whatever the take is in. Melodyne, AnthemScore, Hookpad
and the DAWs all show the scale and can pull stray notes onto it. This adds a **key** to the
project: found in the transcription's notes or chosen by hand, shown on the piano roll's lanes
in both tabs, written into the score, and the target of a **Snap to Scale** command.

It builds on the editor design (`2026-09-19-midi-editor-design.md`), the tempo design
(`2026-09-27-tempo-detection-design.md`, whose Detect button it shares) and the MusicXML design
(`2026-09-27-musicxml-export-design.md`, whose `fifths` it fills). Everything it does not mention
is unchanged.

## 1. Goals and non-goals

Goals

- One press finds the key of the transcription; the KEY controls set or clear it by hand.
- With a key set, the roll's lanes show the scale: in-scale lanes light, out-of-scale lanes
  dark, the tonic's lanes tinted, in both tabs.
- Snap to Scale moves the selection (or every note) to the nearest scale degree, as one
  undoable edit; drums are left alone.
- The MusicXML export carries the key signature and spells a flat key in flats.
- The key is saved in the project. A project without one opens with none.
- Every rule in `NeuralSheetCore` behind `swift test`.

Non-goals

- Modes beyond major and natural minor, key changes, a key from the audio (the notes are
  cleaner and already there; the key needs a transcription).
- Chord detection or a chord lane.
- Transposition by an interval as its own command: the arrow keys already move a selection by
  semitones and octaves, and Select All makes that the whole document.

## 2. Decisions

| Question | Decision |
|---|---|
| Estimator | Krumhansl–Kessler: the pitch-class histogram of the melodic notes weighted by duration, correlated with the 24 major and minor profiles; the best correlation wins. Nil with no melodic notes. |
| Spelling | By key signature: sharps for a positive `fifths`, flats for a negative one. F♯ major is +6; E♭ minor is −6. |
| Controls | In the Edit toolbar's tempo group, after Detect: `KEY`, a tonic button whose menu is None and the twelve pitch classes (`C♯ / D♭` where two names apply), and a mode button with Major and Minor, enabled once there is a tonic. |
| Detect | The tempo group's Detect button finds the tempo, the downbeat and the key together. Its tooltip says so. |
| Highlight | Out-of-scale lanes take the dark lane colour, in-scale lanes the light one, the tonic's lanes the light one under a 10 % accent wash; with no key, the lanes stay by key colour. The keyboard is untouched: it is a piano. |
| Snap to Scale | Edit menu, after Quantize, `⇧⌘K`; the selection, or everything with nothing selected; a note between two scale degrees goes to the lower. |
| Saved | `key` in `project.json`, optional; absent is none. Part of the dirty rule. |

## 3. Core (`NeuralSheetCore`)

```swift
public struct MusicalKey: Equatable, Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case major, minor }
    public var tonic: Int                         // pitch class 0…11
    public var mode: Mode
    public var fifths: Int                        // the key signature
    public var name: String                       // "E♭ minor"
    public var tonicName: String                  // "E♭"
    public var scalePitchClasses: [Int]
    public func contains(pitch: Int) -> Bool
    public func nearestScalePitch(_ pitch: Int) -> Int
    public static func tonicMenuName(_ pitchClass: Int) -> String   // "C♯ / D♭"
}

public enum KeyEstimator {
    public static func estimate(notes: [NoteEvent]) -> MusicalKey?
}

extension NoteDocument {
    public func snapToScale(_ ids: Set<NoteID>, key: MusicalKey) -> EditBatch   // "Snap to Scale"
}
```

`ProjectState` and `ProjectContent` gain `key: MusicalKey?`.

Tests: `fifths` and names for every major and minor tonic; `nearestScalePitch` in C major (C♯
to C, F♯ to F, B♭ to A, a scale note to itself) and in a flat key; the estimator on a C major
scale, on an A minor sequence leaning on the tonic and the leading note, on drums alone (nil);
Snap to Scale moves the out-of-scale notes and leaves the drums; the project state round-trips
a key and reads none from a file without one.

## 4. App

- `EditorState.key: MusicalKey?`; `setKey(_:)`, `setKeyTonic(_:)`, `setKeyMode(_:)`,
  `detectKey()` (from the document's events), `snapSelectionOrAllToScale()` on the model
  (`AppModel+Tempo.swift` becomes the home of both detections; the key commands in
  `AppModel+Editing.swift`).
- `detectTempo()` also calls `detectKey()` once the tempo has landed, when there is a
  document.
- `musicXMLData()` passes `editor.key?.fifths ?? 0`.
- `projectContent()`, `projectState(audioFileName:)` and the open path carry the key.

## 5. UI

- `EditToolbar`: the KEY label and two buttons after Detect; Detect's tooltip becomes "Find
  the tempo, the downbeat and the key".
- `PianoRollView.key: MusicalKey?`, set from the model in both tabs; `drawLanes` picks the
  colours by scale membership when it is set. `TimelinePalette.laneTonic` is the accent at 10 %.
- Edit menu: `Snap to Scale`, `⇧⌘K`, disabled outside the Edit tab or without a key.

## 6. Departures from the inventory

- §7.5: with a key set, the lanes are coloured by the scale rather than by key colour.

## 7. Tests and verification

- Core tests as in §3; build warning-free; `swift test` green.
- By hand: Detect on a transcription in a clear key names it; the lanes show the scale; Snap
  to Scale pulls a stray note onto it and Undo puts it back; the exported score carries the
  key signature; a saved project reopens with its key.

## 8. Order of work

1. **core**: `MusicalKey`, `KeyEstimator`, `snapToScale`, the project fields, tests.
2. **app**: the editor state, the commands, the detection, the export, the project.
3. **ui**: the toolbar controls, the lanes, the menu item.
4. **docs**: AGENTS.md departures, the changelog.
