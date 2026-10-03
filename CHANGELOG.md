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
- Loop playback: Loop on the top bar, or `l`, repeats the marked range, or the whole take without one.
- Playback speed: the SPEED pill on the top bar plays the take slower or faster with its pitch unchanged.
- Tempo from the music: Tap on the Edit toolbar (or `t`) sets it from your taps, Detect finds it and the downbeat in the audio.
- Export the transcription as sheet music: File → Export MusicXML… writes a score any notation program opens.
- The project's key: Detect finds it, the KEY controls on the Edit toolbar set it, the piano roll shows its scale, and Edit → Snap to Scale pulls stray notes onto it.
- A Score tab: the transcription as sheet music, following the playhead.
- Arrange the score: click a part's name in the Score tab for its clef, transposition or tab in any tuning, switch to pages with a title, and File → Export PDF… prints it.
- Stems: turn it on in the Transcribe toolbar, download the Stems model in Settings, and Transcribe separates drums, bass, vocals and the rest before transcribing each.
- Open `.m4a`, `.aac`, `.caf` and the audio of `.mp4`, `.m4v` and `.mov` video files.
- See how sure the model is about each note: View → Show Confidence shades the piano roll by it, Edit → Select Doubtful Notes picks out the uncertain ones, and Settings → Model can drop notes that are too short or too unsure as they arrive.
- Set the time signature and add tempo changes on the ruler, or let Detect follow the take's tempo through the whole recording; the grid, the score and the exports follow.
- Clean up a transcription in bulk from the Edit menu: transpose by an interval, scale the velocity or take it from the audio, make a line legato, join or split notes, humanize a passage, and swing the grid from the Edit toolbar.
- Bring a MIDI file in over the take: File → Import MIDI…, or drop a `.mid` on the window, as the transcription or added to it.
- Chord symbols: Detect names the harmony from the notes, a lane above the piano roll and the score show it, click a symbol to correct it, and the MusicXML export carries it.
- Edit → Track Pitch follows slides, bends and vibrato inside each note from the audio, draws them on the piano roll, and exports them as pitch bend on monophonic MIDI tracks.
- Name the sections and write the words: markers on the ruler (⌥M) become rehearsal marks in the score and the exports, and Edit → Lyric… or Paste Lyrics… puts syllables under the voice line.
- Play the MIDI through your own SoundFont (Settings → Audio), pan each instrument from its strip, hear a click that follows the tempo (CLICK in the master panel, `k`), and record to a count-in.
- Record what your Mac is playing, or one app, with Audio → Input → System Audio; no loopback driver needed.
- Send the transcription to a DAW: Audio → MIDI Output plays it live into any MIDI destination, and the MIDI chip on the Edit and Score toolbars drags the file straight onto a track.
- Export the separated stems as audio files (File → Export Stems…) and the transcription as it sounds (File → Export Audio…): the MIDI alone, or the mix as heard.
- Keep versions of the notes: Edit → Versions saves one by name (and one automatically before every run), restores any, and ghosts one behind the roll to compare.

### Changed

- The synth plays each note's velocity, and the export tempo is the project tempo.
- The ORIG / MIDI mix, the output level and MUTE are in the sidebar's master panel rather than the top bar.
- Trackpad panning of the timeline is smooth.
- Clicking the timeline, or pressing Return in a field, gives the keyboard back to the transport.
- The window is titled after the project.
- The transcription engine is now written in Swift, so it runs on the Mac's GPU without any C++ and can be built for iOS.

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
