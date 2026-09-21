# Changelog

All notable changes to NeuralSheet are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

Work towards v2 starts here: user-experience improvements beyond NeuralNote parity, chosen from [Discussions](https://github.com/bring-shrubbery/neural-sheet/discussions).

### Added

- An app icon: three piano-roll notes on graphite, as a layered macOS 26 icon (`app/NeuralSheet/AppIcon.icon`).
- An Edit tab with full MIDI editing on the piano roll (select, move, resize, draw, erase, duplicate, reassign instrument, velocity, snap and quantize to a tempo grid, undo/redo, revert to transcription); the transcription is saved in the session.
- Automatic releases: every code change on `main` that passes CI is published as a signed, notarized `.dmg` (and zip) on a GitHub release, tagged with the next patch version (`docs/release.md`).
- A website at [neural-sheet.quassum.com](https://neural-sheet.quassum.com) (`web/`, Astro on Cloudflare) with the latest download and the `/appcast.xml` feed redirect.
- Updates install from inside the app (Sparkle): a check on launch and daily, a prompt with the release notes, install and relaunch. The status-bar notice and its link to the releases page are gone.
- The editor auditions notes: a note sounds, with its instrument, velocity and its strip's fader, mute and solo, when it is clicked, dragged across pitches, moved, inserted, nudged, or given another instrument, pitch or velocity.
- A right-click on a note opens a floating card with the selection's instrument, start, length, pitch and velocity, so nothing has to be set from the sidebar.
- In the Edit tab, a click on empty roll space places the playhead there.
- Return / Enter goes to start.

### Changed

- The synth plays per-note velocity; the export tempo is the project tempo, set on the Edit toolbar (and still in the Export dialog).
- The output level and MUTE live in the sidebar's master panel, under the master meter, rather than in the top bar.
- Trackpad panning of the timeline is smooth: the bands are drawn as windows that slide with the scroll rather than as layers the width of the whole take, a wheel over the roll pans time and pitch together, and pitch pans by the pixel rather than a key at a time.
- Clicking the timeline, or pressing Return in a field, gives the keyboard back to the transport, so Space plays again after editing a number.

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
