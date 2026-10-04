# Host checks

The maintainer's checklist for the Audio Unit in the hosts the design names (Audio Unit design
§4): Logic Pro as the sandboxed reference, GarageBand, Ableton Live, Reaper and MainStage. CI
proves the plugin builds and passes `auval`; it never opens a host. Every push to `main`
releases the plugin, so run this against a release's image (or `Scripts/package.sh` output on
a Mac with the certificate), and file what fails as an issue that names the host, its version
and the step.

## Open items

These are not done yet. Tick them here (with the date and host versions) when they are.

- [ ] **The host matrix itself.** None of the hosts below has been driven with the plugin. Run
      the common steps in each, Logic Pro first.
- [ ] **The virtual MIDI source from the sandboxed extension** (steps 7 and 8). Send MIDI to host
      creates the CoreMIDI source "NeuralSheet Plugin" inside the extension's sandboxed
      process. It was checked in an in-process harness only, never from a host-loaded,
      sandboxed extension. If no host lists the source, look for the extension's log line
      "The MIDI source could not be created." and for a sandbox denial (`log stream --predicate
      'subsystem == "com.quassum.neuralsheet.plugin.au" OR sender == "Sandbox"'`).
- [ ] **Open in NeuralSheet from the sandboxed extension** (step 10). It writes into the App
      Group and calls `NSWorkspace.open` on `neuralsheet://open?path=…` from the extension's
      process. That call has not been seen to work from a host-loaded extension; the app's
      side (the URL check, the move into `~/Music/NeuralSheet`) is tested.
- [ ] **The first release with the plugin.** The packaging (`Scripts/package.sh`) ran locally
      with the Developer ID up to notarization; the notarization and stapling of the
      plugin's image have only run in the Release workflow. Check that the release has
      `NeuralSheet-Plugin-vX.Y.Z-macos-arm64.dmg`, that it opens without a Gatekeeper warning
      on a Mac that never built the plugin, and that `spctl -a -vv -t exec "/Applications/NeuralSheet Plugin.app"`
      says `source=Notarized Developer ID`.

## Known caveats (expected, not failures)

- **The synth starts about 20 ms late after a locate.** The plugin's synth renders ahead of the
  transport on a thread of its own; when the host jumps, it begins a new stretch a lead
  ahead, so the first ~20 ms after each locate or start in the middle of a note are silent.
  The MIDI sent to the host is scheduled in the render cycle and is not delayed.
- **An offline bounce has no synth.** The synth runs in real time; a host rendering faster than
  real time (bounce, export, freeze) gets the track's audio through the plugin and silence
  from the synth. Record the MIDI and bounce an instrument instead.
- **The virtual source and Open in NeuralSheet are unchecked from the sandbox** (open items
  above). A failure there is a bug to file, not a known limitation, until the items are ticked.
- **The host must feed the plugin to capture.** Record and Arm capture what the host renders
  through the effect. Most hosts stop processing an idle track when the transport is
  stopped, so with the host stopped, enable input monitoring or record on the track, or
  capture while the host plays.
- **Ten minutes.** A capture stops at ten minutes; a saved take longer than that keeps its first
  ten minutes and says "Saved with its first 10 minutes only".

## Before you start

1. NeuralSheet (the app) is installed and has a model (NeuralSheet › Settings › Model).
2. Remove development copies so the host loads the release: `pluginkit -m -v -i
   com.quassum.neuralsheet.plugin.au` lists every registered copy; `pluginkit -r <path>`
   for each one that is not `/Applications/NeuralSheet Plugin.app/…`.
3. Install the image: drag NeuralSheet Plugin into Applications, open it once (the window shows
   the version), close it.
4. `auval -v aufx NSht Qssm` ends with `AU VALIDATION SUCCEEDED.`
5. Have a session with an audio track that plays at least 30 s of music with a clear melody,
   and an empty instrument track (a software instrument with a piano).

## The common steps

Do these in every host, with the host-specific details from the sections below. Expected
results are under each step.

1. **Insert** "Quassum: NeuralSheet" as an effect on the audio track and open its window.
   - The window opens at 720 × 420 or larger and resizes. The header says whether the host is
     playing, and its position.
   - With ORIG / MIDI on ORIG and no take, the track sounds exactly as without the plugin (it
     passes audio through).
2. **Record 20 s.** Start the host, press Record, press Stop after about 20 s. Then once more
   with Arm: press Arm with the host stopped, start the host, stop it after about 20 s.
   - The waveform draws while capturing; after Stop it shows the take and "Take: 0:20" or so.
   - With Arm, capture starts with the host's transport and ends when the host stops.
3. **Transcribe** with Automatic instruments (and once with Stems on, if the Stems model is
   installed).
   - Progress shows; notes appear on the roll as the run goes; Cancel stops it.
   - With no model installed the plugin says to download one in NeuralSheet › Settings › Model.
4. **Play.** With the host stopped, press Play in the plugin; then start the host from the
   take's start.
   - Host stopped: the plugin plays the take from its own buffer with the synth, and the
     playhead says it is the plugin's.
   - Host playing: the playhead follows the host (its position less where the capture started),
     and the plugin's Play is disabled.
   - ORIG / MIDI crossfades the track's audio and the synth; mute, solo and the faders act on the
     synth's instruments; the master changes the output level.
   - Locate the host a few times: the synth re-attacks about 20 ms late (caveat), nothing hangs.
5. **Drag the chip** ("Drag the MIDI") onto the instrument track.
   - A MIDI region appears, named after the audio track when the host gives the plugin the
     track's name (else "NeuralSheet Transcription"), with the notes on the host's bars at its
     tempo.
   - Dragging to the Finder writes a `.mid`; with ⌥ held, a `.musicxml`.
6. **Send MIDI to host.** Set the instrument track to record from the MIDI source "NeuralSheet
   Plugin" (host sections), arm it, turn on Send MIDI to host in the plugin, and record in
   the host from before the take's start to past its end.
   - The source is listed by the host only after Send MIDI to host is first turned on.
   - The recorded notes match the roll and line up with the audio (within a few
     milliseconds); the instrument plays them live as they are sent.
   - Stopping the host, or turning Send MIDI off, leaves no note hanging.
7. **Locate while sending.** Jump the host to the middle of the take and play.
   - Notes sounding at the new position re-attack; nothing hangs.
8. **Save and reopen.** Save the session, quit the host, reopen the session, open the plugin.
   - The take, the roll, the instruments, the mix, the strips and Send MIDI are as they were,
     with no re-transcription. A take over ten minutes says it was saved cut.
9. **Bounce** the audio track offline (if the host can).
   - The bounce has the track's audio at the mix's ORIG share and no synth (caveat).
10. **Open in NeuralSheet.**
    - NeuralSheet opens a project named after the track, saved in `~/Music/NeuralSheet` (a
      free name, "Name 2" and so on, when one exists), with the take and the notes. With an
      unsaved project open, the app asks about it first.
    - With NeuralSheet not installed, the plugin says so and links the website.
11. **Remove** a second instance of the plugin, and close the plugin window while a run is in
    progress.
    - The host does not stall or crash; the run finishes or is cancelled with the instance.

## Logic Pro (the sandboxed reference)

Logic loads every AUv3 out of process, in the sandbox, which is how the extension is meant to
run; check it first and most thoroughly.

- Rescan: Logic Pro › Settings › Plug-in Manager, select Quassum › NeuralSheet, Reset & Rescan
  Selection. It must say "successfully validated".
- Insert: on the audio track's channel strip, an Audio FX slot › Audio Units › Quassum ›
  NeuralSheet.
- Step 6: on the software instrument track, set its MIDI input to "NeuralSheet Plugin" in the
  track inspector if your Logic offers a per-track input; otherwise make sure nothing else is
  sending MIDI, since Logic records every input. Record-enable the track.
- Step 9: File › Bounce › Project or Section, Offline on; and once with Offline off (real
  time), where the synth should be heard.
- Step 2 with the host stopped needs input monitoring on the audio track (the "I" button) for
  the plugin to receive audio.

## GarageBand

- Insert: select the audio track, Smart Controls (B) › Plug-ins › an empty slot › Audio Units ›
  Quassum › NeuralSheet.
- Step 6: GarageBand records every MIDI input on the selected software instrument track; select
  the track, record-enable it, start recording.
- Step 9: Share › Export Song to Disk is the offline render.
- GarageBand has no plug-in manager; if the plugin is missing, quit GarageBand, open NeuralSheet
  Plugin once and relaunch.

## Ableton Live

- Settings › Plug-Ins: turn on Use Audio Units (and Use Audio Units v3 where your Live offers
  it), then Rescan. The plugin is under Plug-Ins › Audio Units › Quassum.
- Insert: drag NeuralSheet onto the audio track's device chain.
- Step 6: Settings › Link, Tempo & MIDI › MIDI Ports: "NeuralSheet Plugin" input, Track on. On
  the MIDI track, MIDI From "NeuralSheet Plugin", arm, record in the Arrangement view.
- Step 9: File › Export Audio/Video renders offline.
- Live's tracks keep processing with the transport stopped, so Record works without playing.

## Reaper

- Preferences › Plug-ins › AU: make sure Audio Units are on; Clear cache / re-scan. The plugin
  is listed in the FX browser under AU (as "AU: NeuralSheet (Quassum)" or similar).
- Insert: the track's FX button › Add › AU › NeuralSheet.
- Step 6: Preferences › Audio › MIDI Inputs: enable "NeuralSheet Plugin" (it appears once Send
  MIDI to host is on; reopen Preferences if it is not listed). On the instrument track, Record
  input › Input: MIDI › NeuralSheet Plugin › All channels; arm, record.
- Step 9: File › Render with "Full-speed Offline", and once with "Online Render".
- Run step 4 also with Preferences › Audio › Buffering › Anticipative FX processing off; with it
  on, Reaper renders the track ahead of the playhead, which can move the plugin's playhead
  and the synth earlier than the music. Note the result either way.

## MainStage

MainStage has no arrangement, so there is no track to drag to or record into; what it checks is
the plugin in a live set.

- Insert: in a patch, the audio channel strip (an input from your interface or a playback
  plugin) › an Audio FX slot › Audio Units › Quassum › NeuralSheet.
- Step 2: Record and Stop (MainStage's transport rarely runs, so Arm may never start); the
  channel strip must have audio running through it.
- Step 5: drag the chip to the Finder only.
- Step 6: in another patch or layer, a software instrument channel strip whose MIDI input is
  "NeuralSheet Plugin" (the channel strip's MIDI Input in the Inspector). Turn on Send MIDI
  to host and press Play in the plugin: the instrument plays the notes.
- Step 8: save the concert, quit, reopen, select the patch: the plugin's session is restored.
- Steps 9 and 10: no bounce; Open in NeuralSheet as in the common steps.
- Switch patches while the plugin plays: nothing hangs.

## On this machine (when this checklist was written)

No host was installed (`ls /Applications` has no Logic Pro, GarageBand, Ableton Live, Reaper or
MainStage), so nothing here was run. `Scripts/validate.sh` (Release, team-signed, `pluginkit
-a`, `auval -v aufx NSht Qssm`) passed with only the system bridge's CurrentPreset warning.
