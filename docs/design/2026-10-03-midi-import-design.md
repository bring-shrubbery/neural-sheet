# MIDI import — Design

Spec: [issue #15](https://github.com/bring-shrubbery/neural-sheet/issues/15).

`MidiFileWriter` is the only MIDI code in the app. This adds its inverse, `MidiFileReader`, and
a File → Import MIDI… command that lays a file's notes over the loaded take: as the transcription
when there is none yet, or as one undoable edit (replacing or adding) when there is.

It builds on the projects design (`2026-09-21-projects-design.md`) for the state machine and on
the meter and tempo map design (`2026-10-03-meter-and-tempo-map-design.md`) for what "the grid at
its defaults" and "the file's tempo map" mean. Everything this document does not mention is
unchanged.

## 1. Goals and non-goals

Goals

- A correct, defensive SMF reader with a round-trip test against the writer.
- Import as transcription or as an edit, from the menu or by drop, only over a take.

Non-goals

- MIDI-only projects. Controllers, bends, pedal, lyrics, markers. Several files at once.

## 2. Decisions

| Question | Decision |
|---|---|
| Reader output | `MidiFile { ticksPerQuarter: Int?, smpte: (fps, ticksPerFrame)?, tempoMap: [TempoEvent(tick, microsecondsPerQuarter)], timeSignatures: [(tick, TimeSignature)], tracks: [MidiTrack(name, notes: [NoteEvent])] }` plus `allNotes: [NoteEvent]` sorted. Seconds are computed by the reader; callers never see ticks except through `tempoMap` / `timeSignatures` for the grid. |
| Tempo map in format 1 | Tempo events from every track are merged by tick (the spec puts them in track 0, DAWs do not always). |
| Program | Per channel, the last program change at or before the note-on's tick; default 0. Channel 10 (index 9) → `NoteEvent.drumProgram`, program changes on it ignored. |
| Velocity | `NoteEvent.amplitude(forVelocity:)`. Note-on velocity 0 is a note-off. |
| Overlaps | The earliest open note of (channel, pitch) closes first (FIFO), which is what the writer's merged notes produce and what most sequencers mean. |
| Malformed input | `MidiFileReader.Error`: `notMidi`, `unsupportedFormat(2)`, `truncated`, `badTrackLength`. Any throw means no notes. Unknown meta and sysex are skipped by length; an undefined status byte throws `truncated`-style rather than guessing. |
| Where the command lives | File menu after Open Recent, before the exports: Import MIDI… ⌥⌘I, enabled when `state == .audioLoaded || state == .populated`, `!jobActive`, `regionJob == nil`, `importJob == nil`. |
| Drop | `TimelineDocumentView`'s drop target accepts `.mid`/`.midi` beside the audio extensions; `AppModel.importMIDI(url:)` decides. Without a take: the standard dialog "Could not import the MIDI file." / "Load or record audio first, then import a MIDI file over it." |
| Untranscribed take | `installDocument(rawNotes: notes)` then `transition(to: .populated)`, the path a finished run takes; `transcription.sourceSampleCount` is set from the take so the project saves and reopens. If `editor.grid` equals `TempoGrid()` (defaults) and the file has a tempo or a time signature, the grid takes the file's first tempo and first time signature; a file with several tempo events gives a map only when the project's grid is at its defaults, through `replaceMap` with segments at the bars the events fall on (events not on a bar line round to the nearest bar). |
| Transcribed take | The standard three-button alert: "Replace the notes", "Add to the notes", Cancel. Replace = `document.delete(all) + paste(notes, at: 0)` in one batch titled "Import MIDI"; Add = `paste(notes, at: 0)`; both through `replaceDocumentAndCommit`; the inserted ids become the selection. The grid is untouched. |
| Confidence | Imported notes have `confidence = nil` (not from the model). |
| Extent | The roll's scroll range already comes from `max(duration, notes' last end)`; checked, and fixed if it does not. |

## 3. Core (`Packages/NeuralSheetCore/MidiFileReader.swift`, `MidiFileReader+Events.swift`)

```swift
public struct MidiFile: Equatable, Sendable {
    public var format: Int
    public var tempoMap: [MidiTempoEvent]            // tick, microsecondsPerQuarter; sorted
    public var timeSignatures: [MidiTimeSignatureEvent]
    public var tracks: [MidiTrack]                   // name, notes (seconds)
    public var allNotes: [NoteEvent]
    public var firstBpm: Double?                     // from tempoMap.first
    public var firstTimeSignature: TimeSignature?
}

public enum MidiFileReader {
    public enum Error: Swift.Error, Equatable { case notMidi, unsupportedFormat(Int), truncated, badTrackLength }
    public static func read(_ data: Data) throws -> MidiFile
    public static func read(url: URL) throws -> MidiFile
}
```

A small `ByteCursor` struct does bounds-checked reads (`u8`, `u16`, `u24`, `u32`, `vlq`, `bytes(n)`),
each throwing `truncated`. Tick→seconds is a prefix sum over the tempo map, per track, as the
events are walked (ticks are monotone within a track).

Tests (`MidiFileReaderTests`):
- Round trip: 200 random note sets (programs incl. drums, overlapping same pitch, velocities)
  through `MidiFileWriter` in each overflow mode, read back, compared to within 1/960 of a
  quarter at the export tempo and equal programs/velocities after the writer's own merging.
- A hand-built type-0 file with running status, a tempo change mid-way, a program change, and a
  velocity-0 note-off.
- SMPTE division. Format 2 throws. A file cut short throws `truncated`. A track with a wrong
  length throws `badTrackLength`.
- Open notes at end of track close at the track's last tick.

## 4. App

- `AppModel+MIDIImport.swift` (new): `canImportMIDI`, `importMIDI()` (the open panel, `UTType.midi`),
  `importMIDI(url:)`, the two landing paths, the grid adoption.
- `NeuralSheetApp.swift`: the menu item.
- `TimelineDocumentView.swift`: the drop accepts `.mid`/`.midi` and routes them.
- `Dialogs.swift`: `presentImportChoice(fileName:on:completion:)` if the existing three-button
  helper does not fit.

## 5. Changelog

"Bring a MIDI file in over the take: File → Import MIDI…, or drop a `.mid` on the window, as the
transcription or added to it."
