# Audio Unit plugin — Design

Spec: [issue #27](https://github.com/bring-shrubbery/neural-sheet/issues/27). Parent design; the
work is cut into sub-issues (§5).

NeuralNote's reach came from being a plugin. NeuralSheet is standalone, and its project file,
engine, audio layer and drawing code are now shared by design (see the iOS design). An AUv3
effect that passes audio through, captures a clip on demand, transcribes it with the same engine
in the extension's own process, shows the same roll, and hands the MIDI back through a drag or a
virtual MIDI source closes the gap without a second code base.

**VST3 decision.** The repository is Apache 2.0. The VST3 SDK is GPLv3 or a proprietary Steinberg
licence; linking it would make the plugin GPLv3 or need an agreement. Neither is this issue's
to decide. The plugin ships as an Audio Unit; the VST3 question is recorded here and left to
the maintainers (the `PluginCore` module is kept free of AU types so a wrapper remains possible).

## 1. Goals and non-goals

Goals

- An AUv3 (`aufx`, manufacturer `Qssm`, subtype `NSht`) that validates clean, captures the
  host's audio on demand, transcribes it on device, shows the roll, and gets MIDI into the host
  by drag and by a virtual MIDI source synced to the host transport.
- Session state survives a host save; *Open in NeuralSheet* hands the take and notes to the app.

Non-goals

- Editing or score in the plugin (the app is the editor). Streaming transcription. AUv2, CLAP,
  Windows, VST3 (see above).

## 2. Decisions

| Question | Decision |
|---|---|
| Project | `plugin/project.yml` for xcodegen (as the iOS app), generating `plugin/NeuralSheet-Plugin.xcodeproj` with two targets: `NeuralSheet Plugin.app` (a thin container whose only job is to register the extension and show one window with the version and an "Open NeuralSheet" button) and the `NeuralSheetAU.appex` extension embedded in it. The Mac app's `project.pbxproj` is untouched. The container is released beside the app's disk image, signed and notarised by the same workflow. If the main project is ever generated too, the extension moves into the main app; the extension's code does not change for that. |
| Why not embed in the main app now | Embedding needs an Embed App Extensions phase in the main `project.pbxproj`, which the rules forbid editing by hand. |
| Audio path | `AUAudioUnit` subclass in Swift with an `internalRenderBlock` written against the render thread rules: copy input to output, and when `capturing` (an atomic) copy input frames into a preallocated ring (`CaptureRing`, 10 minutes at the host rate, allocated on `allocateRenderResources`). A capture is started/stopped from the UI; the main thread drains the ring into a `SourceAudio` when the capture stops. Record while playing: arming starts the capture on the host's first `transportStateBlock` playing edge. |
| Transcription | The extension process runs `TranscriptionEngine` (Metal when available) over the captured take exactly as the app does, with the same post-run filter settings read from the shared settings. |
| Models and settings | An App Group container, `6WCYZER5LX.com.quassum.neuralsheet`: `Models/` and `global.settings`. Sub-issue C moves the Mac app's models and settings there with a one-time migration at launch (the app is not sandboxed and reads the group path directly; the extension is sandboxed and needs the group entitlement). Recordings and projects stay where they are. The group is team-prefixed rather than `group.com.quassum.neuralsheet`: macOS lets a team-prefixed group in on the code signature, while a `group.` one needs a provisioning profile naming it, which the Developer ID release does not embed; without one the app is refused the container. A copy the system keeps out (ad hoc, another team) keeps `~/Library/NeuralSheet/models`. The plugin has no downloader: with no model it sends the user to the app's Settings › Model. |
| UI | `AUViewController` hosting SwiftUI: a transport-aware header (host playing/stopped, position), Record / Arm, Model + Instruments, Stems, progress, the roll (`UIView`-free: the shared CoreGraphics drawing in an `NSView`, the same `PianoRollView+Drawing` split the iOS work produces), per-instrument strips (mute/solo/fader, no pan), the mix of host audio vs the plugin's synth (a crossfade on the output: host audio × a, synth × b — the synth is an `InstrumentSynthBank` on an `AVAudioEngine` inside the extension rendering into a buffer the render block mixes in, driven by `NoteScheduler` against the host's sample time when the host plays, or its own clock when stopped), *Drag MIDI out* (the chip from #21, same code), *Send MIDI to host*, *Open in NeuralSheet*. Resizable, minimum 720 × 420. |
| Playhead | While the host plays, the roll follows `musicalContextBlock`/`transportStateBlock` sample time minus the capture's start sample; when stopped, the plugin's own transport plays the take from the capture buffer through the output (so the user can audition without the host). |
| MIDI to host | A virtual CoreMIDI source "NeuralSheet Plugin" (`MIDISourceCreateWithProtocol`), fed by the same `MidiOutRing` + sender thread as the app's MIDI out, with note timestamps from the host's render host time, so a MIDI track set to record from that source captures the transcription in time with the host transport. Chosen over AU MIDI-output because host support for MIDI out of an effect is uneven; the issue text's "plugin's MIDI output" is met this way. |
| State | `fullState` holds the take as ALAC (`AVAudioFile` into memory, capped at 10 minutes), the notes (`ProjectTranscription` JSON), the selection of instruments, the model size and the mix. Restoring rebuilds the roll without re-transcribing. |
| Open in NeuralSheet | Writes a `.neuralsheet` package into the group container's `Handoff/` folder and opens `neuralsheet://open?path=…` (the app registers the scheme in sub-issue E and moves the package to the user's Music folder on open, asking for a name). |
| Validation | `auval -v aufx NSht Qssm` must pass with no warnings in CI (the container app is built, the extension registered with `pluginkit -a`, `auval` run, then `pluginkit -r`). |

## 3. Shared code

`PluginCore` is a folder of sources compiled by the extension and free of AU types: capture ring,
state coding, the take-to-source conversion, the handoff writer. The audio layer, engine, drawing
and strings are the same files the Mac and iOS targets compile (xcodegen source lists with
excludes, as the iOS design).

## 4. Checks

Each sub-issue: Mac build and tests unchanged; the plugin project builds warning-free; `auval`
clean from A on; host checks in Logic Pro (sandboxed reference), GarageBand, Live, Reaper and
MainStage listed in the issue and run by a maintainer before release.

## 5. Sub-issues

A. Scaffold: xcodegen project, container + extension, passthrough render block, `auval` clean,
   CI job.
B. Capture: the ring, Record / Arm with the host transport, take drained to `SourceAudio`,
   the waveform shown.
C. App Group: models and settings migration in the Mac app; the extension transcribes with
   progress; the roll (after the drawing split).
D. Playback and MIDI: the in-extension synth and mix against host audio, host-synced playhead,
   the virtual MIDI source, the drag chip.
E. State and handoff: `fullState` with ALAC, restore, *Open in NeuralSheet* with the URL scheme.
F. Host matrix, release packaging beside the app, docs.

## 6. Changelog

The Mac app's changelog gets one line when F lands: "NeuralSheet is also an Audio Unit: capture a
clip on any track, transcribe it in the plugin, and drag the MIDI onto an instrument track or
record it from the plugin's MIDI source."
