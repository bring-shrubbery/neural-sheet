# NeuralSheet Plugin

NeuralSheet as an Audio Unit: an effect you put on an audio track that captures a clip, transcribes it on your Mac, shows the notes, and gets the MIDI into your DAW.

## Install

1. Install NeuralSheet and download a model in NeuralSheet › Settings › Model. The plugin uses the app's models and downloads nothing itself.
2. Download `NeuralSheet-Plugin-vX.Y.Z-macos-arm64.dmg` from the same [release](https://github.com/bring-shrubbery/neural-sheet/releases) as the app, open it and drag NeuralSheet Plugin into Applications.
3. Open NeuralSheet Plugin once. That registers the plugin with macOS; you can close the window.
4. In your DAW, insert **Quassum: NeuralSheet** as an effect on an audio track. If it is not listed, rescan the Audio Units (see the host notes).

To update, install the next release's image the same way and open it once. To remove it, quit your DAWs and move `/Applications/NeuralSheet Plugin.app` to the Bin. Requires macOS 26 on Apple silicon.

## Use

- **Record** captures what reaches the plugin from now until **Stop**; **Arm** waits for the host to play and captures until it stops. A take is up to 10 minutes.
- **Transcribe** runs the model on the take, with the instruments and Stems you chose; the roll fills as it goes.
- Play the take from the plugin while the host is stopped, or let the playhead follow the host. ORIG / MIDI mixes the track's audio with the plugin's synth; each instrument has mute, solo and a fader.
- **Drag the MIDI** onto an instrument track (or the Finder) for a MIDI file at the host's tempo, named after the track; hold ⌥ for MusicXML.
- **Send MIDI to host** plays the notes into a virtual MIDI source, "NeuralSheet Plugin", in time with the host's transport: set an instrument track to record from it.
- The take and its notes are saved with your session. **Open in NeuralSheet** opens them in the app as a project in `~/Music/NeuralSheet`, for editing and the score.

## Host notes

- **Logic Pro, GarageBand, MainStage** list it under Audio Units › Quassum › NeuralSheet. Logic's Plug-in Manager rescans it.
- **Ableton Live** lists Audio Units under Plug-Ins once Audio Units are switched on in Settings › Plug-Ins; rescan there after installing. Turn on the "NeuralSheet Plugin" MIDI input in Settings › Link, Tempo & MIDI to record from it.
- **Reaper** lists it as "AU: NeuralSheet (Quassum)"; Preferences › Plug-ins › AU rescans. Enable "NeuralSheet Plugin" under Preferences › Audio › MIDI Inputs to record from it.
- The plugin's synth is heard live only: an offline bounce or export renders the track's audio but not the synth. Record the MIDI and play it with an instrument for a bounce.
- After the host jumps to a new position the synth starts about 20 ms late. The MIDI sent to the host is not delayed.

`HOSTS.md` is the maintainers' checklist for each host.

## Development

Design: `docs/design/2026-10-03-audio-unit-design.md`. AUv3 effect `aufx` / `NSht` / `Qssm`, sharing the Mac app's packages.

`make project` regenerates `NeuralSheet-Plugin.xcodeproj` from `project.yml` (`brew install xcodegen`); edit the spec, never the generated project. The Mac app's project is untouched.

Two targets: `NeuralSheet Plugin.app`, a container with one window whose launch registers the extension, and `NeuralSheetAU.appex`, the sandboxed extension embedded in it. `NeuralSheetAU/` is the audio unit, its render block and its SwiftUI view; `PluginCore/` is the shared logic, free of AU types (the capture ring, the capture session behind Record / Arm / Stop, the take, the installed models, the saved state with the take as ALAC, the Open in NeuralSheet package); `Container/` is the app. Files the app also compiles (`SourceAudio`, the engine wrapper and the stem separator with its C++ bridge, the timeline's painters and their theme) are listed by path in `project.yml`; a pre-build phase runs the app's `Scripts/build-engine.sh macos` for `libdemucs.a` (the `app/ThirdParty/demucs.cpp` submodule and CMake are needed).

The extension reads the models and `global.settings` the app keeps in the App Group container `~/Library/Group Containers/6WCYZER5LX.com.quassum.neuralsheet` (both targets declare the group); it downloads nothing itself. Open in NeuralSheet writes a project into the group's `Handoff/<uuid>/` and opens `neuralsheet://open?path=…` (`app/NeuralSheet/Shared/HandoffURL.swift`, shared with the app, which moves it into `~/Music/NeuralSheet`). Its log: `log stream --level info --predicate 'subsystem == "com.quassum.neuralsheet.plugin.au"'`.

Build with `xcodebuild -project NeuralSheet-Plugin.xcodeproj -scheme "NeuralSheet Plugin" -destination 'platform=macOS,arch=arm64' build`, or open the project in Xcode; run the container once and the effect shows up in hosts as "Quassum: NeuralSheet". `xcodebuild … test` runs `PluginCoreTests`, which compile `PluginCore/` directly.

`Scripts/validate.sh` checks the version, builds Release into a temporary folder, registers the extension with `pluginkit`, runs `auval -v aufx NSht Qssm` and unregisters it; CI runs it on every push. `NS_PLUGIN_SKIP_AUVAL=1` builds only; `NS_PLUGIN_SIGNING=team|adhoc` picks the signature (team when an Apple Development identity is installed). On a Mac where the team-signed extension has run, an ad hoc one asks for access to its sandbox container and waits for the answer, so keep to team signing there.

The plugin carries the Mac app's version. `MARKETING_VERSION` in `project.yml` must equal the app's, and the component's integer `version` is it packed as `major << 16 | minor << 8 | patch`; change all three together and run `make project` (`Scripts/check-version.sh` checks, in CI and in the release). The release builds with its own version and stamps the matching integer into the extension.

`Scripts/package.sh` is the release's packaging: a Developer ID archive, the version stamp, the checks and the signed disk image (`docs/release.md`, "Audio Unit").
