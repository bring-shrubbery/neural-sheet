# Live MIDI output and the MIDI drag chip — Design

Spec: [issue #21](https://github.com/bring-shrubbery/neural-sheet/issues/21).

`InstrumentSynthBank.schedule` already turns the scheduler's `SynthEvent`s into 3-byte MIDI
messages one buffer ahead of the render time. The MIDI output is a second consumer of those
same events: they are pushed into a lock-free ring from the render thread and a sender thread
turns them into timestamped CoreMIDI packets. The drag chip is the old NeuralNote drag-out
reduced to a toolbar chip with a file promise.

It builds on the playback design §4 and the MIDI export design. Everything this document does
not mention is unchanged. **The render thread rules in CLAUDE.md apply to §3.**

## 1. Goals and non-goals

Goals

- Any CoreMIDI destination; synth-accurate timing; channels, programs, CC 7/10 as the export;
  no hanging notes on any transition; the built-in synth optionally muted.
- A MIDI (and ⌥ MusicXML) drag chip on the Edit and Score toolbars.

Non-goals

- Clock / MTC / MMC, MIDI in, bend over MIDI out, per-instrument destinations.

## 2. Decisions

| Question | Decision |
|---|---|
| Channel map | `MidiChannelMap` extracted from `MidiFileWriter` into Core: `assign(programs:, mode:) -> [Int: Int]` (program → channel 1…16, drums 10), shared by the writer and the output. |
| Timing | Each `SynthEvent` carries `sampleOffset` from the buffer's render time. The ring entry stores the event plus the buffer's `mHostTime` and `mSampleTime`; the sender converts `hostTime + sampleOffset / sampleRate` to a `MIDITimeStamp` with `mach_absolute_time` units through `AudioConvertNanosToHostTime`. CoreMIDI schedules timestamped packets itself, so a sender that runs up to ~20 ms late is still on time. |
| Ring | `MidiOutRing`: a fixed single-producer single-consumer ring of 4 096 entries (`UnsafeMutablePointer`, head/tail as `Atomic<Int>` from the existing atomic pattern). Full ring → the event is dropped and a counter bumped (visible only in a debug log); never a block. |
| Sender thread | A `Thread` at `qualityOfService = .userInteractive` with a time-constraint policy (`thread_policy_set` as the audio thread uses), woken by a semaphore the render thread signals (`DispatchSemaphore.signal()` is async-signal-safe and non-blocking) at most once per buffer. It drains the ring into a `MIDIEventList` (UMP MIDI 1.0 channel voice messages) and calls `MIDISendEventList`. |
| CoreMIDI objects | `MidiOutput` (new, `nonisolated`, main-thread API + the sender): one `MIDIClientCreateWithBlock` (the block receives setup changes → the menu's list refreshes), one output port, the chosen `MIDIEndpointRef`. Destinations listed via `MIDIGetNumberOfDestinations` / `MIDIObjectGetStringProperty(kMIDIPropertyDisplayName)` and `kMIDIPropertyUniqueID`. |
| What is sent | Note on/off from the ring; at play start, seek, destination change and when the mixer changes: program change, CC 7 (`gainDb` → 0…127 through the fader's own curve: 0 dB = 100, like the synth), CC 10 (pan), per used channel, from the main thread through the same port (ordered before the ring's notes by timestamp = now). Mute/solo: `InstrumentSynthBank` already skips events for muted programs? It does not — gain is applied on the mixer. The output applies them itself: the sender holds an `audible[program]` table the main thread writes (single-word atomics per program, as the roll's highlight does), and drops events for inaudible programs. |
| All notes off | `MidiOutput.panic()` from the main thread on stop, seek, loop wrap (the engine already notifies the main thread of a wrap for the scheduler), speed change, destination change, quit: CC 123 and CC 64 = 0 on every used channel, then per sounding note a note-off (the sender keeps a 16 × 128 bit set of sounding notes so a destination that ignores CC 123 is covered). |
| Mute the synth | `GlobalSettings.midiOutMutesSynth` (default true). While a destination is set and the toggle is on, `InstrumentSynthBank` applies an extra zero gain to the sub-mix (the click has its own path and the original is on the source node, both untouched). |
| Audition | `InstrumentSynthBank.audition` also calls `MidiOutput.sendImmediate(noteOn/Off)` from the main thread. |
| Menu | Audio → MIDI Output ▸ None, ──, destinations, ──, "Mute Built-in Synth While Sending" (checkmark). `GlobalSettings.midiOutUniqueID: Int32?`. |
| Drag chip | `MidiDragChip` (an `NSViewRepresentable` hosting an `NSView` that is an `NSDraggingSource` + `NSFilePromiseProviderDelegate`), on the Edit and Score toolbars' trailing end: document glyph + "MIDI". `mouseDown` + drag threshold starts a session with an `NSFilePromiseProvider` for `.midi` (or `.musicxml` with ⌥ held at mouse-down); the delegate writes the file with the same code the export menu uses, into `FileManager.temporaryDirectory/NeuralSheet/<name>`, and the promise's `writePromise` completion removes nothing (the receiver owns the file at the destination; our temp copy is removed in `draggingSession(_:endedAt:operation:)`). A click without a drag runs `requestExport()`. Disabled (dimmed, no drag) when `!canExport`. Tooltip "Drag the MIDI into a DAW or the Finder | ⌥ for MusicXML · click to export". |

## 3. Render thread

- `InstrumentSynthBank.schedule`: after the synth block call for each event, if `midiOutEnabled`
  (one atomic read per call, hoisted) → `ring.push(entry)` (a few stores and one atomic release).
  After the loop, if anything was pushed, `semaphore.signal()`.
- No CoreMIDI call, no allocation, no lock on this path.

## 4. Core

- `MidiChannelMap.swift` with tests (shared with the writer; the writer's tests keep passing).
- `GlobalSettings`: `midiOutUniqueID`, `midiOutMutesSynth`.

## 5. App

- `Audio/MidiOutput.swift`, `Audio/MidiOutput+Sender.swift`, `Audio/MidiOutRing.swift`.
- `InstrumentSynthBank+MidiOut.swift` (the push and the mute).
- `PlaybackEngine`: `panic()` calls at stop/seek/wrap/speed.
- `App/AppModel+MidiOut.swift`: the menu's model, `setMidiDestination`, mixer → CC pushes.
- `UI/Toolbar/MidiDragChip.swift`; `EditToolbar.swift` and `ScoreToolbar.swift` place it.
- CLAUDE.md / AGENTS.md: the departures sentence's "there is no Drag MIDI out" clause becomes
  "the MIDI leaves by File → Export MIDI… or the MIDI chip's drag on the Edit and Score
  toolbars".

## 6. Changelog

"Send the transcription to a DAW: Audio → MIDI Output plays it live into any MIDI destination,
and the MIDI chip on the Edit and Score toolbars drags the file straight onto a track."
