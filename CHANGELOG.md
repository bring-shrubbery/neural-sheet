# Changelog

All notable changes to NeuralSheet are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

Work towards v2 starts here: user-experience improvements beyond NeuralNote parity, chosen from [Discussions](https://github.com/bring-shrubbery/neural-sheet/discussions).

### Added

- An app icon.
- An Edit tab: edit the transcription's notes on the piano roll, with undo and revert.
- Cut, copy and paste notes.
- A right-click on a note opens a card with its instrument, start, length, pitch and velocity.
- Notes are auditioned as they are clicked, moved or changed.
- A right-click on an instrument strip changes, splits or deletes the whole instrument.
- Re-transcribe a stretch of the take: drag on the ruler, then Re-transcribe on the toolbar.
- A stereo split in the master panel: the original in the left ear, the MIDI in the right.
- Projects: a `.neuralsheet` file holds the audio, the transcription, the edits and the settings.
- A welcome window to create or open a project.
- Updates install from inside the app.
- Automatic releases: every change on `main` that passes CI is published as a signed disk image.
- A website at [neural-sheet.quassum.com](https://neural-sheet.quassum.com).
- Return / Enter goes to start; `[` and `]` step the mix.

### Changed

- The synth plays each note's velocity, and the export tempo is the project tempo.
- The ORIG / MIDI mix, the output level and MUTE are in the sidebar's master panel rather than the top bar.
- Trackpad panning of the timeline is smooth.
- Clicking the timeline, or pressing Return in a field, gives the keyboard back to the transport.
- The window is titled after the project.

### Removed

- Drag MIDI out; File → Export MIDI… is how a transcription leaves the app.
- The autosaved session; a project file is where work is kept.

## [1.0.0-checkpoint] — 2026-09-19

The first complete build. Feature parity with the NeuralNote v2 standalone app, reimplemented natively for macOS.

### Added

- Native macOS app (SwiftUI, AppKit, AVAudioEngine) for macOS 26 on Apple silicon.
- Recording from any input device, and loading of `.wav`, `.aiff`, `.flac`, `.mp3` and `.ogg` files by drop or dialog.
- Transcription with MuScriptor through `muscriptor.cpp` on Metal, with instrument selection, streaming results into the piano roll, progress and cancellation.
- Model management: small, medium and large models downloaded from Hugging Face with resume and SHA-256 verification.
- Playback through the built-in General MIDI synthesizer with a source/MIDI mix, master level, and per-instrument level, mute and solo with meters.
- MIDI export by drag-and-drop and by file dialog: one track per instrument, drums on channel 10, configurable tempo and channel-overflow policy.
- A timeline (waveform, ruler, piano roll, keyboard) that redraws only what changed and holds 120 Hz on ten-minute files.
- Settings and session persistence, keyboard shortcuts, tooltips, an update check, and an Audio menu for device selection.
- A pure-Swift core package with 187 tests.

### Changed from NeuralNote

- Standalone app only; no AU or VST3 plugin.
- Playback uses Apple's DLS synthesizer instead of the MuseScore soundfont, so it sounds different.
- Files live under `~/Library/NeuralSheet/`; models already in `~/Library/NeuralNote/models` are reused.

[Unreleased]: https://github.com/bring-shrubbery/neural-sheet/compare/v1.0.0-checkpoint...HEAD
[1.0.0-checkpoint]: https://github.com/bring-shrubbery/neural-sheet/releases/tag/v1.0.0-checkpoint
