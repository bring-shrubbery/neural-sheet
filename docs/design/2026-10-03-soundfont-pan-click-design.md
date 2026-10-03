# SoundFont, pan, click and count-in — Design

Spec: [issue #19](https://github.com/bring-shrubbery/neural-sheet/issues/19).

Playback is Apple's DLS synth with its built-in General MIDI bank, one synth per instrument into
a sub-mix (`InstrumentSynthBank`), events placed by `NoteScheduler` from the source node's render
block. All four additions fit that graph: the DLS synth loads SoundFonts through a property, the
sub-mix inputs already have a pan, the click is one more synth fed by a second scheduler, and the
count-in is the click running before the recorder starts.

It builds on the playback design in `2026-09-17-neuralsheet-design.md` §4, the loop and speed
designs, and the meter and tempo map design (beats for the click). Everything this document does
not mention is unchanged. **The render thread rules in CLAUDE.md apply to every line in §3.**

## 1. Goals and non-goals

Goals

- A global sound bank applied to every synth; per-instrument pan in the project and the MIDI;
  a click from the grid with its own voice and fader; a count-in that starts the take on a
  downbeat.

Non-goals

- Per-instrument banks, effects, pan automation, tap during the count-in.

## 2. Decisions

| Question | Decision |
|---|---|
| Loading a bank | `kMusicDeviceProperty_SoundBankURL` on each DLS synth's audio unit (`AudioUnitSetProperty` with a `CFURL`), set before the program change. Both `.sf2` and `.dls` load. On a load error the property call fails → the bank setting reverts to System, the dialog shows once, and the synths keep the system bank. |
| Where the bank lives | `GlobalSettings.soundBankPath: String?` (security-scoped bookmark data as well, `soundBankBookmark: Data?`, since the app is sandboxed and the file is outside the container). The bank is resolved at launch and whenever the setting changes. |
| Applying a change | `InstrumentSynthBank.setSoundBank(url:)`: for each existing instrument, `allNotesOff`, set the property, re-send the program change. The audio unit reloads in place; no graph rebuild. Done on the main thread under `lock` as `apply(mixer:)` is. |
| Drums with SF2 | The DLS synth maps MIDI channel 10 to the percussion bank itself; the drum instrument's program change stays as today (bank select MSB 120 / LSB 0 then program 0 for GM2-style banks; if the bank has no percussion preset the synth plays preset 0, which is the "default rather than silence" the issue asks for). |
| Pan storage | `InstrumentChannelSettings.pan: Double = 0` (−1…1), Codable with default. `InstrumentMixerState` carries it; `apply(mixer:)` sets `node.pan = Float(pan)` on each synth node (an `AVAudioMixing` property of the node feeding the sub-mixer, main thread). |
| Pan UI | `InstrumentStrip`: a 40 pt horizontal slider under the fader, centre detent at 0 (snaps within ±5), double-click resets, tooltip "Pan | double-click to centre". `AppModel.setPan(program:_:)`. |
| Pan in MIDI | `MidiTrackSpec.pan: Int` (0…127 = `(pan + 1) × 63.5` rounded); CC 10 written after the program change at tick 0. |
| Click voice | A dedicated `SynthInstrument` with program `InstrumentSynthBank.clickProgram = 129` (outside 0…128, never in the mixer's strips, never exported) on MIDI channel 10 so it draws from the percussion bank: note 76 (hi wood block) at velocity 100 for beats, note 75 (claves) at 118 for downbeats, each 60 ms long. Its own fader (`clickGainDb`), not part of the sub-mix's solo logic (solo mutes instruments, never the click). |
| Click events | `ClickTrack.events(grid:, duration:) -> [NoteEvent]` in Core: one note per `.beat`/`.bar` grid line from `min(0, …)` through `duration`, with `program = clickProgram`. Rebuilt on the main thread whenever the grid or the duration changes and handed to a second `NoteScheduler` (`clickScheduler`) in `InstrumentSynthBank`, which `schedule(...)` drives in the same call right after the notes' scheduler, with the same `renderTime`, `frameCount` and rate, so it follows seek, loop and speed for free. `clickEnabled` is a single-word atomic the render block reads; when false the click scheduler is advanced but its events are dropped (so turning it on mid-bar is in time). |
| Click UI | Master panel: a CLICK button in the MUTE style with a short fader to its right; `k` toggles. `ProjectState.clickEnabled`, `clickGainDb` (default −6). |
| Count-in | `AppModel.toggleRecord` with `GlobalSettings.countInBars > 0`: the engine starts (silent source of `countIn` bars at the grid's first segment tempo and meter), the click scheduler is given the count-in's events and `clickEnabled` forced on, state becomes `.countingIn` (a new `AppState` case between `.empty` and `.recording`; `canPlay` false, the Record button lit and pulsing as during recording), the status bar's record area shows "Count-in · 4", "3", … from the playhead poll. When the playhead reaches the count-in's end the recorder starts (`Recorder.start()`, which is sample-accurate to the engine's clock as it is today), `editor.grid.offsetSeconds = 0`, state `.recording`. Esc or `r` during the count-in: engine stops, back to `.empty`, nothing written. |
| Click while recording | `GlobalSettings.clickWhileRecording`: when true the click scheduler keeps running through the take at the project grid; when false `clickEnabled` returns to the project's value (which is off during recording unless the user turned it on). The recorder taps the input, not the output, so the click never enters the file. |

## 3. Render-thread notes

- `InstrumentSynthBank.schedule` calls `clickScheduler.collect` after `scheduler.collect`; the
  click instrument's schedule block sits in the same fixed table at index `clickProgram`, so no
  lookup is added.
- `clickEnabled` is an `OSAllocatedUnfairLock`-free `Atomic<Bool>` (the existing single-word
  atomic pattern), read once per render call.
- The count-in's silent source is a `SourceAudio` with one zero channel; the render block's path
  for it is the ordinary one. Its retirement follows the existing `Unmanaged` grace period.

## 4. Core

- `ClickTrack.swift`: events from the grid; tests on 4/4 and 3/4 maps with a tempo change (count,
  accents, times).
- `InstrumentChannelSettings.pan`; `MidiTrackSpec.pan` and the CC 10 bytes (test).
- `GlobalSettings`: `soundBankPath`, `soundBankBookmark`, `countInBars`, `clickWhileRecording`.
- `ProjectState`: `clickEnabled`, `clickGainDb`.
- `AppState.countingIn`.

## 5. App

- `InstrumentSynthBank+SoundBank.swift`, `InstrumentSynthBank+Click.swift` (keep the main file
  under 400 lines by moving the audition into `+Audition.swift` if needed).
- `AudioSettingsView.swift`: Sound bank, Count-in, Click while recording.
- `InstrumentStrip.swift`: pan. `MasterPanel.swift`: CLICK and fader. `StatusBar`: the count-in
  text. `AppModel+Recording` (extracted from `AppModel.swift` if the count-in pushes it past
  400 lines): the count-in state machine. `KeyboardShortcuts.swift`: `k`.

## 6. Changelog

"Play the MIDI through your own SoundFont (Settings → Audio), pan each instrument from its
strip, hear a click that follows the tempo (CLICK in the master panel, `k`), and record to a
count-in."
