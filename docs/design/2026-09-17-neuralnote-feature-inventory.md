# NeuralNote v2 — Feature & Behaviour Inventory

Source of truth: `/Users/antoni/Projects/NeuralNote` @ commit `20ca45a` ("NeuralNote v2 initial commit").
Project version **2.0.0** (`CMakeLists.txt:2`), company "Dr. Audio", bundle id `com.draudio.neuralnote`,
plugin codes `DrAu` / `NRNT`, formats **AU, VST3, Standalone**, product name "NeuralNote".
C++23, min macOS deployment target **11.0**.

Everything below is what a Swift reimplementation must reproduce. Items marked **[PLUGIN]** are only
meaningful inside a DAW host and are candidates for exclusion from a standalone-only v1.
Guesses are marked "(inferred)".

---

## 1. Window / layout

### 1.1 Editor window and scaling
- Authored ("1.0×") UI size: **1280 × 800** px (`NnLook.h:309-310`, `nn::metrics::editorWidth/editorHeight`).
- The UI **never reflows**. `NeuralNoteMainView` is always laid out at 1280×800 and mapped onto the
  window with an affine `scale()` transform (`PluginEditor.cpp:43-64`). Every metric below is in
  authored pixels.
- Resizable with fixed aspect ratio 1280/800 = 1.6 (`NnEditorConstrainer.cpp:13`).
- Scale range: **0.5 (640×400) … 2.0 (2560×1600)** (`NnLook.h:314-315`). The upper bound is further
  clamped to the display the window is on: `min(usableWidth*0.99/1280, usableHeight*0.90/800, 2.0)`
  (`NnEditorConstrainer.cpp:38-44`, `NnEditorConstrainer.h:57-58`). `userBounds` = display area minus
  menu bar and dock.
- Clamping is `max(0.5, min(requested, maxForDisplay))` — the minimum wins even on a tiny display
  (`NnEditorConstrainer.cpp:47-52`).
- Actual applied scale = `min(width/1280, height/800)` of the current window (`PluginEditor.cpp:52-53`).
- Scale persists to `global.settings` under `editorScale`, written on resize-end (plugin hosts) and on
  editor close (standalone, whose native frame never delivers `resizeEnd`) (`PluginEditor.cpp:26-36`,
  `NnEditorConstrainer.h:36-40`). Not rewritten if unchanged by < 0.0005 (`PluginEditor.cpp:96`).
- Preset scales in the Settings menu: **50 %, 75 %, 100 %, 125 %, 150 %, 200 %** (`NeuralNoteMainView.cpp:286`).
- Corner resizer drawn as three diagonal lines at 30 %/55 %/80 % of its size, colour `#6b7078` when
  hovered/dragged else `#4e535b` (`NnLook.cpp:277-292`).
- Editor background fill `bgRoot` `#131417`.

### 1.2 Region layout (`NeuralNoteMainView::resized`, `NeuralNoteMainView.cpp:85-103`)
```
┌──────────────────────────────────────────────── top bar, h=54 ───────────────┐
├──────────────┬───────────────────────────────────────────────────────────────┤
│ sidebar      │ toolbar, h=44                                                 │
│ w=262        ├──────┬────────────────────────────────────────────────────────┤
│              │gutter│ waveform (AudioRegion), h=126                           │
│              │ w=46 ├────────────────────────────────────────────────────────┤
│              │      │ time ruler, h=22                                       │
│              ├──────┼────────────────────────────────────────────────────────┤
│              │ key- │ piano roll (rest of height)                            │
│              │board │                                                        │
├──────────────┴──────┴────────────────────────────────────────────────────────┤
│ status bar, h=26                                                             │
└──────────────────────────────────────────────────────────────────────────────┘
```
- Heights/widths (`nn::metrics`, `NnLook.h:215-226`): topBar 54, toolbar 44, waveform 126, ruler 22,
  statusBar 26, sidebar 262, sidebarHeader 38, instrument strip 76, timelineGutter 46.
- The gutter (46 px) + keyboard column sit **outside** the horizontal viewport; waveform, ruler and
  piano roll live inside one horizontally-scrolling `Viewport` (`VisualizationPanel.cpp:143-168`), so
  their time axes are always aligned. Viewport shows only a horizontal scrollbar
  (`VisualizationPanel.cpp:27`), thumb colour `faderTrack` `#26282e`, transparent track/background.
- Update-check notification: bounds `(right-460, bottom - 26 - 10 - 30, 460-11, 30)` — i.e. 10 px above
  the status bar, `menuRowHeight`=30 tall (`NeuralNoteMainView.cpp:95-99`).
- Instrument menu overlay covers the whole main view (`NeuralNoteMainView.cpp:101`), anchored to
  `sidebar.position + (sidebarWidth-10, 33)` (`Sidebar.cpp:172-175`, `nn::metrics::menuAnchorRight=10`,
  `menuAnchorTop=33`).

### 1.3 Top bar (`TopBar.cpp`)
Left → right: wordmark, transport (5 buttons), time readout, Model button, [flexible gap],
mix pill, volume pill, MUTE button, settings button.
- Paddings: left 18, right 14, group gap 16, transport gap 2 (`TopBar.cpp:17-20`).
- Background `bgTopBar` `#17181c`, 1 px bottom border `divStrong` `#24262c`.
- **Wordmark** (`TopBar.cpp:33-65`): a 9×9 accent rounded square (r=2) at x+4.5, then "NEURALNOTE" in
  `wordmark()` font (Inter 15 pt / 600) with **0.14 em tracking**, colour `textBright` `#f2f4f7`;
  then "v2" in `wordmarkVersion()` (JetBrains Mono 9 / 500), 0.06 em tracking, colour `textFaint`
  `#5d626b`, offset +9 px right of the name and +2 px down. Reserved width 230.
- **Transport**: 5 buttons of 34×30 (`transportButtonW/H`): Back (skip-to-start, filled icon 15 px,
  `textIcon`), Play/Pause (toggle; play 15 px, pause 16 px, `textPrimary`, on-background
  `bgControlActive` `#22242a`), **Loop (permanently disabled, tooltip "Loop (not implemented yet)")**,
  Follow-playhead (toggle, stroked 16 px + filled flag overlay, on colour `accent`, on-background
  `accentFillActive` = accent @14 %), Record (toggle, filled 16 px; idle `recIdle` `#7a3b44`, on `rec`
  `#ff6b8a`, on-background rec@14 %).
- **Time display** (`TimeDisplay.cpp`): `mm:ss.dd / mm:ss.dd`, monospaced; position font `transportTime()`
  (mono 15/500), total `transportTotal()` (mono 11/400). 1 px vertical rules on both edges (`divStrong`).
  Side padding 14, gap 8. Position colour `textBright` when `canPlay()` else `textScale` `#4e535b`;
  total colour `textFaint`. Total shows `--:--.--` with no audio. Updated on vblank, repainted only
  when the formatted string changes.
- **Model button**: label `"MODEL: SMALL|MEDIUM|LARGE|NONE"` (uppercased), font `sectionHeader()`
  (Inter 10/600) with 0.09 em tracking, padding (11,11,7), height 30 (`controlHeight`), toggles the
  model panel; lit (`accentFillActive`, text `accentText` `#a8c2ff`) while the panel is open.
- **Mix pill**: label "ORIG" (`textMuted` `#797f88`) … 86 px slider … "MIDI" (`accentText`), fonts
  `pillLabel()` (Inter 9.5/500), 0.08 em tracking, pill padding 12, gap 9, corner radius 6
  (`controlCorner`), background `bgControl` `#1c1e23`. Slider fill `accent @80 %`, track `faderTrackTop`
  `#2b2e35`. Dimmed to `DISABLED_ALPHA` 0.38 while there are 0 transcribed notes.
- **Volume pill**: speaker icon 13 px, 74 px slider, 30 px right-aligned dB readout with 1 decimal
  (`String(value, 1)`), font `meta()` (mono 9/400). Dimmed to 0.38 unless `canPlay()`.
- **MUTE button**: label "MUTE" + muted-speaker icon 14 px, padding (11,11,7); on-background
  `bgMuteActive` `#3a2f22`, on-colour `warn` `#f2a33c`. Bound to the `MUTE` plugin parameter.
- **Settings button**: 32 px wide, stroked gear icon 14 px, background `bgControl`.

### 1.4 Sidebar (`Sidebar.cpp`)
- Background `bgSidebar` `#161719`, right border `divStrong`.
- Header 38 px: "INSTRUMENTS" (sectionHeader, 0.13 em tracking, `textLabel` `#7a808a`), a right-aligned
  count of entries (mono 10/400, `textFaintest` `#565b63`), and an 18×18 "+" button (stroked plus 13 px,
  corner radius 4, bg `bgControlSubtle` `#1f2126`, on-bg accent@18 %, on-icon `accentText`). Side padding
  14, header gap 8. The "+" is hidden once a transcription exists.
- Scrollable strip list (vertical scrollbar only), one `InstrumentStrip` per entry, each **76 px** tall.
- Master panel pinned to the bottom, **63 px** tall, top border `divSoft` `#202227`: pad-top 12, label
  "MASTER" (sectionHeader, tracking 0.13, `textLabel`) 12 px tall, gap 10 (`masterMeterTopGap`), then the
  master meter **26 segments, gap 3, height 5** (`NnLook.h:300-302`), unlit colour `bgControlSubtle`.

### 1.5 Instrument strip (`InstrumentStrip.cpp`) — 262 × 76
- Side padding 14, pad-top 11, identity row 22, fader-top gap 9, fader height 11, meter top gap 6,
  meter height 3 (16 segments, gap 2), value column 30 wide with 9 gap.
- Colour chip 22×22, corner radius 5, fill = instrument colour @13 %, border @25 %, 3-letter
  abbreviation centred in mono 8/600 in the instrument colour.
- Name at x=31 (`stripTextInset` = chip 22 + gap 9), font `instrumentName()` (Inter 12/500),
  colour `textStrong` `#dcdfe4` (or `textLabel` + a 1 px strike-through line when muted).
- Meta line below (mono 9/400, `textFaintest`), one of:
  - `"selected · not transcribed yet"` (selected but no notes)
  - `"<n> hits · kit map"` (drums)
  - `"<n> notes · C2-G5"` (melodic; `·` is U+00B7)
- M and S toggles 20×18, corner 4, font `metaStrong()` (mono 9/600); M on = `bgMuteActive` bg /
  `warn` text, S on = `soloButtonBg` (rec@18 %) bg / `rec` text. A soloed row tints its whole
  background with `soloRowTint` (rec@5 %). Row bottom border `divRow` `#1e2024`.
- Fader range **−36 … +6 dB, step 0.1**, double-click resets to 0.0 dB. Fill = instrument colour @85 %
  (or `faderFillMuted` `#3a3d44` when muted), thumb `faderThumb` `#e7e9ec` (or `faderThumbMuted`).
- dB readout right-aligned, 1 decimal, `textDim` `#6b7078`.
- A muted strip draws all its children at `MUTED_ALPHA` **0.5**.
- A strip whose instrument has no notes yet has M/S/fader **disabled**.

### 1.6 Toolbar (`NnToolbar.cpp`) — h 44
- Background `bgRoot`, bottom border `divSoft`. Side padding 14, group gap 12.
- Left: the loaded file's name (without extension) in `filename()` (Inter 12.5/500), `textFile` `#d7dade`.
  Nothing is drawn when the take was recorded or nothing is loaded.
- Right → left: Clear (trash icon, 28×28 square), **Drag MIDI out**, **Export MIDI out**, **EXPORT TEMPO** pill.
- Tempo pill: label "EXPORT TEMPO" (pillLabel, 0.09 em tracking, `textDim`), a 40 px numeric editor,
  and two 7×4 stacked triangles (decorative, gap 2). Background `bgControlAlt` `#1b1d21`, corner 6.
- Button height 28 (`toolbarButton`).

### 1.7 Status bar (`StatusBar.cpp`) — h 26
- Background `bgPanel` `#15161a`, top border `divSoft`. Side padding 14.
- Left segments, font `statusBar()` (mono 9.5/400), colour `textFainter` `#585d65`, separated by
  ` · ` (a `textSeparator` `#33363c` middle dot with 14 px either side):
  `"<n> instrument(s)"`, `"<n> notes"`, `"<lowest> - <highest>"` (only if notes > 0), `"<dd.dd> s"`
  (only if duration > 0).
- Right: a vertical-zoom double-arrow icon 11 px (`zoomIcon` `#585d65`) + 8 px gap + a **74 px** zoom
  slider (range 0…1, track `zoomTrack` `#26282e`, fill `zoomFill` `#6b7078`, thumb `zoomThumb` `#c2c6cc`).
- Transcription progress group sits 24 px left of the zoom control while a run is in flight.

### 1.8 Colour palette (`NnLook.h:33-211`) — exact hex values
Surfaces: `windowBorder #26282e`, `bgRoot #131417`, `bgTopBar #17181c`, `bgSidebar #161719`,
`bgPanel #15161a`, `bgGutter #16171a`, `bgControl #1c1e23`, `bgControlAlt #1b1d21`,
`bgControlSubtle #1f2126`, `bgControlActive #22242a`, `bgMuteActive #3a2f22`.
Dividers: `divStrong #24262c`, `divSoft #202227`, `divRow #1e2024`, `divTick #22242a`, `divOctave #232529`.
Text: `textBright #f2f4f7`, `textPrimary #e7e9ec`, `textStrong #dcdfe4`, `textFile #d7dade`,
`textButton #c2c6cc`, `textIcon #9ba1ab`, `textIconSoft #8e939c`, `textLabel #7a808a`,
`textMuted #797f88`, `textDim #6b7078`, `textFaint #5d626b`, `textFainter #585d65`,
`textFaintest #565b63`, `textScale #4e535b`, `textSeparator #33363c`.
Accent: `accent #6e9bff`, `accentText #a8c2ff`; `accentFillActive` = accent@0.14,
`accentFillButton` = accent@0.09, `accentWashWave` = accent@0.045, `accentWashRoll` = accent@0.03,
`accentWashEdge` = accent@0.14.
Status: `warn #f2a33c`, `rec #ff6b8a`, `recIdle #7a3b44`.
Meters: `meterLow #4f7a52`, `meterMid #8ec98c`, `meterHot` = `warn`.
Waveform: `wavePlayed #7d8797`, `waveUnplayed #3a3f47` (declared; the current painter uses
`wavePlayed` for all bars and overlays a wash), centre line = white @5 %.
Piano roll: `keyWhite #e2e4e8`, `keyBlack #0e0f11`, `keyLabel #7c818a`, `laneBlack #141519`,
`laneWhite #191a1e`, note onset edge = white @35 %.
Faders: `faderTrack #26282e`, `faderTrackTop #2b2e35`, `faderThumb #e7e9ec`, `faderThumbMuted #5a5f67`,
`faderFillMuted #3a3d44`, `volumeFill #8e939c`.
Popups: `popupBg #1b1d21`, `popupBorder #2e3138`, `popupFooterBg #191a1e`, `popupRowHover #22242a`,
`popupTitle #6b7078`, `popupItem #a8adb5`, `popupItemTicked #e7e9ec`, `checkboxBorder #3a3d44`,
`checkboxTick #12131a`, popup shadow = black @55 %.
Empty states: `ctaBorder` = accent, `ctaText` = accentText, `dropZoneBorder #2b2e35`,
`ctaFill` = accent@0.11, `dropZoneFill` = accent@0.015.
Progress: `progressTrack #26282e`, `progressFill` = accent, `progressText` = accentText.
Zoom: `zoomIcon #585d65`, `zoomTrack #26282e`, `zoomFill #6b7078`, `zoomThumb #c2c6cc`.
Chips: fill = colour@0.13, border = colour@0.25. `soloRowTint` = rec@0.05, `soloButtonBg` = rec@0.18.
Global: `DISABLED_ALPHA = 0.38`, `MUTED_ALPHA = 0.5`.

### 1.9 Interaction-state rules (`NnLook.h:377-409`)
- `surfaceFor(idle, on, state)`: if disabled → the plain fill; if pressed → (on ? its own fill :
  `bgControlSubtle`) darkened by 0.15; if hovered and not on → `bgControlSubtle`; else the fill.
- `foregroundFor(idle, on, state)`: hovered **and** on → brightened by 0.12; otherwise the plain colour.
- Disabled controls are drawn as their enabled selves at alpha 0.38 — there is no second colour set.

### 1.10 Fonts (`NnFonts.cpp`)
Bundled TTFs (in `NeuralNote/Assets/Fonts/`, embedded as BinaryData): **Inter** Regular/Medium/SemiBold/Bold,
**JetBrains Mono NL** Regular/Medium/SemiBold. Licences: `Inter-LICENSE.txt`, `JetBrainsMono-OFL.txt` (OFL 1.1).
Rule: anything read as *data* (times, dB, counts, tempo, key labels) is JetBrains Mono; labels and names
are Inter. Sizes are **point heights** (`withPointHeight`), matching CSS px in the mockup.

| accessor | family / size / weight | tracking |
|---|---|---|
| `wordmark` | Inter 15 / 600 | 0.14 em |
| `wordmarkVersion` | Mono 9 / 500 | 0.06 em |
| `transportTime` | Mono 15 / 500 | — |
| `transportTotal` | Mono 11 / 400 | — |
| `filename` | Inter 12.5 / 500 | — |
| `instrumentName` | Inter 12 / 500 | — |
| `buttonLabel` | Inter 11.5 / 500 | — |
| `menuItem` | Inter 11.5 / 400 | — |
| `menuItemTicked` | Inter 11.5 / 500 | — |
| `tempoValue` | Mono 11.5 / 400 | — |
| `sectionHeader` | Inter 10 / 600 | 0.13 em (0.09 on top-bar pills) |
| `pillLabel` | Inter 9.5 / 500 | 0.08–0.09 em |
| `statusBar` | Mono 9.5 / 400 | — |
| `meta` | Mono 9 / 400 | — |
| `metaStrong` | Mono 9 / 600 | — |
| `scaleLabel` | Mono 7.5 / 400 | — |

Letter-spacing ("tracking") is implemented manually: glyph *i* is shifted by `i * trackingEm *
font.heightInPoints`, and justification is applied to the tracked bounding box, baseline-aligned
(`NnLook.cpp:21-76`).

### 1.11 Icons (`NnIcons.h/.cpp`)
All icons are **code-built `juce::Path`s**, not SVGs, each fitted to the rect passed in. Stroked icons
use a shared width **`STROKE_WIDTH = 1.3`**, curved joints, rounded caps. The set:
`skipToStart`, `play`, `pause`, `record`, `loopStroked` + `loopHead`, `followPlayheadStroked` +
`followPlayheadFlag`, `speaker`, `speakerMuted`, `settingsStroked`, `folderStroked`, `downloadStroked`,
`trashStroked`, `triangleUp`, `triangleDown`, `plusStroked`, `crossStroked`, `checkStroked` (drawn at
2 px stroke inside a ticked checkbox), `transcribeStroked` (five bars of rising then falling height),
`verticalZoomStroked` (vertical double-headed arrow).
Other image asset: `NeuralNote/Assets/logo.png` — used only as the macOS/Windows app & plugin icon
(`ICON_BIG`/`ICON_SMALL`), not drawn in the UI.

### 1.12 Popups, menus and tooltips (`NnLook.cpp:116-275`)
- Menu panel: width **244**, corner **8**, header 28, footer 29, row 30, list max height **274**
  (scrolls beyond), pad-x 11, list pad-y 4, checkbox 14 px with corner 3.
- Popup surface: `popupBg` fill + 1 px `popupBorder` rounded outline.
- `PopupMenu` is re-skinned globally by `NeuralNoteLookAndFeel`: tick box on the **right** (JUCE's left
  gutter is unused), nothing drawn for an unticked row, ticked rows use `menuItemTicked` font +
  `popupItemTicked` colour, highlighted rows fill `popupRowHover`, separators are a 1 px `divStrong`
  line in a 9 px row, minimum menu width 180.
- Tooltips: max width **260 px**, vertical padding 6, drawn on the same popup surface, placed away from
  whichever screen edge the pointer is nearest. Delay **800 ms** (`TooltipWindow(this, 800)`).
- The LookAndFeel also colours JUCE's own Standalone "Options" menu and Audio/MIDI settings dialog from
  a 9-colour scheme (`NnLook.cpp:147-155`).

---

## 2. Audio input

### 2.1 Recording (`SourceAudioManager.cpp:98-275`)
- Triggered by the top-bar Record toggle (enabled only in state `EmptyAudioAndMidiRegions` or `Recording`).
- Recordings directory: `<userApplicationData>/NeuralNote/recordings`
  (macOS `~/Library/NeuralNote/recordings`).
- Two files are written **simultaneously** by two `AudioFormatWriter::ThreadedWriter`s (FIFO 32768
  samples each, each on its own `TimeSliceThread`):
  1. `recorded_audio<YYYY-MM-DD_HH-MM-SS>.wav` — native sample rate, **16-bit**, `min(numInputChannels, 2)` channels.
  2. `recorded_audio<...>_downsampled.wav` — **16 kHz, mono, 16-bit** (the model's input).
  Name collisions get `_1`, `_2`, … suffixes.
- Downmix+downsample happens in a single pass per block via `Resampler::processBlock(channels…)`:
  channels are **averaged** (not summed) then low-passed then Lagrange-interpolated
  (`Resampler.cpp:48-95`).
- Anti-alias filter: Butterworth IIR low-pass at `targetRate/2` = **8 kHz**, order **4**, designed with
  `designIIRLowpassHighOrderButterworthMethod` (`Resampler.cpp:16-24`). Applied only when downsampling.
- No maximum recording length is enforced anywhere (inferred: bounded only by disk).
- `mNumSamplesAcquired`, `mNumSamplesAcquiredDown` and `mDuration` (= downsampled samples / 16000) are
  updated per block and read by the UI.
- **[PLUGIN]** On the first block where the host transport is rolling — after **2 settling blocks**
  ("Logic reports a stale playhead position") — the host BPM, time signature, ppq and ppq-of-last-bar
  are read and reduced to (a) `mExportStartOffsetSeconds`, the seconds to add to every exported note so
  that MIDI time 0 is a bar line, and (b) `mHostBpm`, which is written into the `EXPORT_TEMPO` state
  property on stop (`SourceAudioManager.cpp:44-96`, `263-265`). Time signature defaults to 4/4 if absent.
  Both stay **0** for a standalone take or a dropped file.
- On stop: writers flushed/destroyed, threads stopped with a 1000 ms timeout; both WAVs are read back
  into memory (so playback and the waveform use the 16-bit round-tripped audio); peaks are rebuilt from
  the downsampled buffer; state → `AudioLoaded`. If **zero** samples were captured, everything is cleared
  instead.
- Failures show a native message box: "File creation for recording failed." / "Could not load the
  recorded audio sample."

### 2.2 File drop / open (`SourceAudioManager::onFileDrop`, `AudioUtils.cpp`)
- Accepted in states `EmptyAudioAndMidiRegions`, `AudioLoaded`, `PopulatedAudioAndMidiRegions`
  (i.e. not while recording or transcribing) (`CombinedAudioMidiRegion.cpp:42-49`).
- Formats: **.wav, .aiff, .flac, .ogg (Vorbis), .mp3**. WAV/AIFF/FLAC/OGG go through JUCE's
  `AudioFormatManager` (`WavAudioFormat`, `AiffAudioFormat`, `FlacAudioFormat`, `OggVorbisAudioFormat`);
  **.mp3 is decoded with minimp3** (`mp3dec_load`, samples scaled by 1/32768)
  (`AudioUtils.cpp:14-42, 135-157`). The accepted-extension list is derived from these registrations
  plus a hard-coded ".mp3".
- A drop first `clear()`s everything, then loads. On failure: message box
  "Could not load the audio file." / "Check your file format (Accepted formats: .wav, .aiff, .flac,
  .mp3, .ogg)." For an unsupported extension the drop target itself shows
  "Could not load the file." with the dynamically-joined extension list.
- After load: the file is downmixed+resampled to **16 kHz mono** for transcription
  (`resampleBufferToMono`), and separately resampled (keeping its channel count) to the **current device
  sample rate** for playback. Peaks rebuilt; state → `AudioLoaded` (**a drop does NOT start a
  transcription** — the user picks instruments and presses Transcribe).
- `mDroppedFilename` = file name without extension; shown in the toolbar and used to name MIDI exports.
- File chooser ("Select Audio File") is reachable from the "Load audio file" button on the empty
  waveform region; its filter patterns are generated from the same extension list (`AudioRegion.cpp:193-217`).

### 2.3 Storage & resampling on device change
- `mSourceAudio` — playback buffer, always at the current device rate, same channel count as the source.
- `mDownsampledSourceAudio` — **always mono at 16 kHz**, what the model reads (channel 0 only).
- `prepareToPlay` re-resamples `mSourceAudio` if the device rate changed while audio is loaded
  (`SourceAudioManager.cpp:22-41`).

### 2.4 Waveform peaks (`WaveformPeaks.h/.cpp`)
- A min/max **pyramid**: level 0 = one min/max per **64 samples** (4 ms at 16 kHz); each level above
  merges pairs, up to a single top bin.
- A query picks the coarsest level where `binSamples * 16 <= span` (`MIN_BINS_PER_QUERY = 16`), so cost
  is O(1)-ish regardless of span; below **2048 samples** (`RAW_SCAN_MAX_SAMPLES`) it scans the raw
  samples for an exact answer (only possible when the raw buffer is still borrowed).
- `buildFrom` borrows (does not copy) the sample buffer; `append` (used while recording, fed straight
  off the downsampled writer's FIFO) drops the borrowed buffer and unions into partially-filled bins so
  chunked appends equal one full pass.
- Access is guarded by a `CriticalSection`; painting takes a `Reader` that holds the lock for a whole
  frame.

### 2.5 Metering (`RmsMeter.h`, `MeterScale.h`)
- Sliding mean-square over a **50 ms** window (`METER_WINDOW_SECONDS = 0.05`), circular buffer of squares
  with a `double` running sum; `pushSilence` is a no-op once the window is fully zeroed.
- Two meter families: per-instrument (post-fader, mono fold of L/R, published once per block by the
  audio thread) and master (the plugin's own output after the master fader, mono fold).
- Meter scale: **−36 … 0 dB**, mid at **−12 dB**, hot at **−6 dB** (`MeterScale.h:24-29`). Band boundaries
  derive from dB, not index: `segment >= 30*N/36` → Hot, `>= 24*N/36` → Mid. At N=26: 0–16 low,
  17–20 mid, 21–25 hot. At N=16: 0–9 / 10–12 / 13–15. `lit = round((db+36)/36 * N)` clamped.
- Meter ballistics (`NnLevelMeter.cpp`): **instant attack**, release **24 dB/s** (full range drains in
  1.5 s). Repaints only when the lit-segment count changes. Segment corner radius 1.0.
- Driven by one `VBlankAttachment` on the sidebar (`Sidebar::_onVBlankCallback`), dt clamped to 0.1 s.
  A **staleness** check: if the audio thread's frame counter has not moved for
  `max(0.5 s, 2 × blockDuration)`, every meter is fed `METER_MIN_DB` so a bypassed/suspended plugin's
  meters fall instead of sticking.

### 2.6 Clearing
- `NeuralNoteAudioProcessor::clear()` → player reset, source audio cleared (and any *recorded* files
  deleted — only files matching the recordings dir + `recorded_audio` prefix are ever deleted),
  transcription cleared, state → `EmptyAudioAndMidiRegions`, main view reset.
- `clearTranscription()` keeps the audio (state → `AudioLoaded`, or `Empty` if there was no audio).

---

## 3. Transcription

### 3.1 Models (`ModelManifest.h`, `TranscriptionConstants.h`, `NNFileUtils.cpp`)
- Three sizes: `Small`, `Medium`, `Large`; **default `Medium`**.
- HF repo `DamRsn/muscriptor-gguf`, pinned revision
  `d7045f94e8b19427f4ff9542975035e66596e51c`, directory `v1`.
  URL template: `https://huggingface.co/DamRsn/muscriptor-gguf/resolve/<rev>/v1/<file>`.

| size | file | bytes | sha256 |
|---|---|---|---|
| Small | `muscriptor-small-f16.gguf` | 209 425 152 (≈209 MB) | `925f55af65a20ebc4f8b45ceaf095a12b72493d436cb112623cd0041a1af23d4` |
| Medium | `muscriptor-medium-f16.gguf` | 618 442 496 (≈618 MB) | `3850cc9e5b436b17a09bd25b8f2615cb3366ab96a71e7b50f73a793a917fdf03` |
| Large | `muscriptor-large-f16.gguf` | 2 739 142 176 (≈2.7 GB) | `35a750fb1ab1e77195cdc2c0b9b4aeea2f4d59f11f729f02af9920c4854ef72e` |

- Models folder: `<userApplicationData>/NeuralNote/models` → macOS `~/Library/NeuralNote/models`,
  Windows `%APPDATA%\NeuralNote\models`.
- "Installed" = the file exists **with exactly the manifest byte size**. No hash check at load time;
  a wrong-size file is treated as absent and will be replaced by a download.
- Partial download file: `<name>.gguf.<first 8 hex of sha256>.part`. Part files for *other* digests
  (a build pinned to other weights) are deleted on start.
- Resolution order when the stored preference is missing: preferred → `Medium` → first installed →
  none (`NNFileUtils.cpp:66-83`).

### 3.2 Download flow (`ModelDownloader.cpp`, `ModelDownloadPanel.cpp`)
- One `juce::Thread` per size, all owned by one process-wide `SharedResourcePointer<ModelDownloader>`;
  cross-process exclusion via `InterProcessLock("NeuralNoteModelDownload_<size>")` — failing to take it
  reports "Another NeuralNote is already downloading this model".
- Phases: `Idle`, `Downloading`, `Verifying`, `Failed`.
- HTTP: connection timeout **30 000 ms**, up to **5 redirects**, read chunk **1 MiB**,
  `Range: bytes=<offset>-` when resuming.
  - 206 → the `Content-Range` must start with `bytes <offset>-` and end `/ <expectedTotal>`, else the
    part is deleted and it starts over ("Unexpected response from huggingface.co").
  - 200 → whole file; any existing part is deleted and the offset resets.
  - 416 → part deleted, "The partial download could not be resumed".
  - other → "huggingface.co answered HTTP <n>"; retryable only for 5xx.
  - Over-long body → "huggingface.co sent more than the expected size" (non-retryable).
  - Short body → "The connection dropped" (retryable).
  - Write errors → "Could not write to <path>" (non-retryable).
  - Connect failure → "Could not reach huggingface.co".
- Retries: delays **2 000 / 5 000 / 10 000 ms**; the counter resets whenever an attempt wrote any bytes.
- On completion: SHA-256 of the part is compared with the manifest; mismatch deletes it and reports
  "The download was corrupted. Try again". On success the part is renamed over the target file.
- Cancel keeps the part file, so starting again **resumes**. Cancelling is non-blocking; destruction
  waits indefinitely on a verify in flight.
- **Model panel UI** (`ModelDownloadPanel.cpp`): width **440**, corner 8, popup surface; height =
  16 + 18 + 16 + 10 + 3×46 + 2×2 + 10 + 26 + 14 = **~250** (from `getIdealHeight()`); content left
  edge x=20; rows 46 px tall with 2 px gaps, row corner 6, inset 10.
  - Title: "Transcription model" / "No transcription model installed"; subtitle "Tick the model to
    transcribe with." / "Download a model to start transcribing."
  - Each row: checkbox (dimmed to 0.38 when the model is not installed), name (Small/Medium/Large),
    and a meta line: `"618 MB · Recommended"` (hints: Small→"Fastest", Medium→"Recommended",
    Large→"Largest, slowest"), or `"120 MB of 618 MB"` while downloading, or the error message in
    `warn` colour when failed.
  - Size formatting: ≥1e9 bytes → `"x.y GB"` (1 decimal, /1e9), else `"<n> MB"` (rounded, /1e6).
  - Right column (172 px wide): a "Download"/"Resume"/"Retry" button, or a progress bar
    (height 3, corner 2) + a right-aligned "<n>%" (32 px) + a 16 px cancel cross, or the tracked caption
    "VERIFYING".
  - Clicking an installed row selects it (writes `modelSize` to `global.settings`); the in-use row is
    filled with `accentFillActive` and ticked. Hovered installed rows fill `popupRowHover` and show a
    pointing-hand cursor.
  - Footer button "Open models folder" (opens the folder in Finder/Explorer, creating it first).
  - A close cross is shown only when the panel is optional; with **no** model installed and an idle
    roll the panel is **mandatory and cannot be closed** (`VisualizationPanel.cpp:170-191`).
  - Polls at **10 Hz**, even while hidden (so it can reappear if the last checkpoint disappears).

### 3.3 Instrument selection (`InstrumentSelection.cpp`, `InstrumentMenu.cpp`)
- Stored as one comma-separated list of `msl::InstrumentGroup` integer ids in the state property
  `SELECTED_INSTRUMENT_GROUPS`. **Empty = "Automatic" = the model chooses.**
- Ids that the library does not know are dropped on read; duplicates removed; result sorted in
  enumerator order.
- The picker is a custom component (not a `PopupMenu`) because it is multi-select and stays open:
  row 0 is **"Automatic (any instrument)"** (ticked iff the selection is empty; clicking it clears the
  selection), then the **35 named groups** in enumerator order, each toggling on click.
  Header "ADD INSTRUMENT" (tracking 0.13), footer "TICK TO INCLUDE IN TRANSCRIPTION" (tracking 0.04).
  Drop shadow radius 34, offset (0, 14). Escape or a click on the scrim closes it. The menu grabs
  keyboard focus while open and hands it back on close.
- Selecting an instrument immediately creates a **placeholder strip** in the sidebar
  (`InstrumentMixer::setSelectedPrograms`, fed from `InstrumentSelection::selectedPrograms`, which maps
  each group through `msl::programFor`).
- The "+" button and the picker disappear once a transcription exists — the selection is a decoder
  constraint, not a filter, so it can only be changed before a run.

### 3.4 Running a transcription (`TranscriptionManager.cpp`, `MuscriptorEngine.cpp`)
- Entry point: the centred **Transcribe** call-to-action on an empty piano roll. Its label is
  `"Transcribe"` / `"Transcribe 1 instrument"` / `"Transcribe N instruments"` depending on the selection.
  Height 34 (`ctaHeight`), padding 17, icon-gap 9, corner 6, fill `ctaFill` (accent@11 %), accent outline,
  `ctaText` icon + label. Visible while the roll is idle **and** a model is installed; enabled only in
  `AudioLoaded`.
- `launchTranscribeJob()` (`TranscriptionManager.cpp:237-286`):
  1. no-ops unless state == `AudioLoaded` and no job is active;
  2. resolves the model size (falls back to any installed one; aborts silently if none);
  3. `engine.reset()` **before** publishing the `Processing` state, so a cancel click can never be lost;
  4. clears raw/post-processed notes and `finalizedThrough`;
  5. snapshots the instrument selection into `mJobInstruments`;
  6. `InstrumentMixer::resetStoredSettings()` — every fader/mute/solo from the previous run is dropped;
  7. state → `Processing`;
  8. requires **≥ 1 second of audio** (`numSamplesDown >= 16000`), otherwise `clear()`s everything;
  9. queues the job on a 1-thread `ThreadPool`.
- The job calls `Transcriber::load(path, {.use_gpu = true})` — **GPU is always requested; there is no
  CPU/GPU setting in the UI**. `n_threads` is left at the library default 0 (= performance-core count).
  `prelude_forcing` is left at its default `true`. The model is **unloaded before the call returns**
  on every path (success, cancel, failure), because weights + KV cache exceed 1 GB.
- Load failure messages: for `Error::UnsupportedCheckpointVersion`, `"<file> is for another version of
  NeuralNote. Delete it from the models folder, then download it again"`; otherwise `msl::describe(err)`.
- Per-chunk callback (5 s of audio each) stages new notes under a mutex together with
  `finalized_through`, and publishes `progress`; returning `false` cancels.
- Every note gets a **fixed amplitude of 100/127 ≈ 0.7874** (the model predicts no velocity)
  (`MuscriptorEngine.cpp:22`).
- The message thread polls at **30 Hz** (`startTimerHz(30)`); when a drain yields anything it runs
  post-processing and repaints the piano roll (so the UI updates at the model's pace, ~once per 5 s of
  audio, not at 30 Hz).
- On success, the streamed accumulation is **replaced** by `transcribe()`'s authoritative result
  (the streamed one misses notes the model never closed), `finalizedThrough` is set to the audio
  duration, and state → `PopulatedAudioAndMidiRegions`.
- On cancel: `clearTranscription()` — back to `AudioLoaded` with the audio intact.
- On failure: a native message box, title "Transcription failed.", body
  `"The transcription model could not be loaded or run: <reason>."` (or without the reason).
- Cancellation is requested by the status-bar cross; it is **latched** in the UI (the caption and bar
  dim to 0.38) because it is only observed at a chunk boundary, which can be seconds away. The button
  itself stays clickable (cancelling is idempotent).
- Shutdown: `~TranscriptionManager` cancels and waits up to **30 s** for the pool job.

### 3.5 Progress display (`TranscriptionProgress.cpp`)
- Group = caption "TRANSCRIBING" (tracked 0.06 em, `progressText`) + gap 10 + bar **150 × 3**, corner 2
  + gap 10 + "<n>%" right-aligned in 28 px + gap 10 + 16 px cancel cross.
- The caption **pulses**: a raised-cosine between alpha 0.55 and 1.0 with a period of **1600 ms**,
  quantised to hundredths so it does not force a repaint every frame. Driven by a vblank callback;
  repaints only when the percentage or the pulse changes.
- The frontier of the decode is also shaded in the piano roll (see §7).

---

## 4. Note data model

- `NoteEvent` (`Lib/Model/NoteEvent.h`): `{ double startTime, endTime (seconds); int pitch 0-127;
  double amplitude 0-1; int program (0-127 or 128 = drums) }`. `isDrum() == (program == 128)`.
  `NUM_INSTRUMENT_IDS = 129`.
- Sort order: `(startTime, program, pitch, endTime)`.
- **The only post-processing** is `mergeOverlappingNotesWithSamePitch` — notes of the same
  *program and pitch* whose intervals overlap are merged into one (keeping the later end). Keyed on the
  program too, so two instruments on the same note are preserved. No minimum-duration filter, **no
  quantisation, no scale/key filtering, no velocity shaping** in v2.
- Three parallel note lists exist in `TranscriptionManager`: `mRawNotes` (the model's own output,
  accumulated across chunks), `mPostProcessedNotes` (what the piano roll draws and what is exported),
  and a copy handed to the `NoteScheduler`.
- The model routes drums itself: the library derives `is_drum` from the instrument group and then
  overwrites `program` with 128, so no melodic note can carry it (including the reference's program-96
  quirk).
- `InstrumentMixer` derives, per program, `{noteCount, lowestPitch, highestPitch}`, then a list of
  `InstrumentEntry { program, name, abbreviation, colour, noteCount, lowestPitch, highestPitch }` in
  **ascending program order** (so drums, program 128, are always last and the sidebar order is stable as
  chunks arrive). An entry with `noteCount == 0` is a user-selected placeholder.
- Names/abbreviations/colours come from a 35-row table in `InstrumentInfo.cpp`, keyed by
  `msl::InstrumentGroup`; programs outside the named groups fall back to the library's `program_<n>`
  label, the program number as a chip, and a hue spun from `program % 128`
  (`Colour::fromHSL(p/128, 0.22, 0.62)`).

### 4.1 The 35 instrument groups — name, chip, colour
| group (enum id) | UI name | chip | colour |
|---|---|---|---|
| AcousticPiano (0) | Piano | PNO | `#3372ff` |
| ElectricPiano (1) | Electric Piano | EPN | `#85a0ff` |
| Organ (3) | Organ | ORG | `#1f5fc1` |
| AcousticGuitar (4) | Acoustic Guitar | AGT | `#45d1a8` |
| CleanElectricGuitar (5) | Electric Guitar | GTR | `#7aeed6` |
| DistortedElectricGuitar (6) | Distorted Guitar | DGT | `#388d6d` |
| ElectricBass (8) | Bass | BAS | `#9033ff` |
| AcousticBass (7) | Acoustic Bass | ABS | `#c685ff` |
| Contrabass (12) | Contrabass | CBS | `#5b1fc1` |
| Violin (9) | Violin | VLN | `#f9295d` |
| Viola (10) | Viola | VLA | `#ff4363` |
| Cello (11) | Cello | VLC | `#ea175e` |
| StringEnsemble (15) | Strings | STR | `#ff6471` |
| SynthStrings (16) | Synth Strings | SST | `#c11f63` |
| OrchestralHarp (13) | Harp | HRP | `#ff8585` |
| Trumpet (19) | Trumpet | TPT | `#ffc458` |
| Trombone (20) | Trombone | TBN | `#e07f25` |
| FrenchHorn (22) | French Horn | HRN | `#f2a33c` |
| BrassSection (23) | Brass | BRS | `#ffdd81` |
| Tuba (21) | Tuba | TBA | `#b46029` |
| SopranoAndAltoSax (24) | Alto Sax | ASX | `#feac85` |
| TenorSax (25) | Tenor Sax | TSX | `#e8704a` |
| BaritoneSax (26) | Baritone Sax | BSX | `#ae4532` |
| Flutes (31) | Flute | FLT | `#c3d94e` |
| Oboe (27) | Oboe | OBO | `#c9e868` |
| EnglishHorn (28) | English Horn | EHN | `#d0f385` |
| Clarinet (30) | Clarinet | CLR | `#bbc638` |
| Bassoon (29) | Bassoon | BSN | `#9c9c39` |
| Voice (17) | Voice | VOX | `#4bc1e7` |
| SynthLead (32) | Synth Lead | LED | `#86d7fe` |
| SynthPad (33) | Synth Pad | PAD | `#329bae` |
| Drums (36) | Drums | DRM | `#77869f` |
| Timpani (14) | Timpani | TMP | `#949fb9` |
| ChromaticPercussion (2) | Chromatic Perc. | CPR | `#b3b9d1` |
| OrchestraHit (18) | Orchestra Hit | OHT | `#616f80` |

(Families: keys blue, guitars green, bass purple, strings pink, brass orange, saxes red-orange,
winds chartreuse, voice/synth cyan, percussion slate. Build-time `static_assert`s enforce that all 35
colours and all 35 group ids are distinct.)

### 4.2 Mixer state
- Per-program gain/mute/solo live in the **plugin ValueTree**, in an `INSTRUMENT_MIXER` child with one
  `INSTRUMENT` node per program (`PROGRAM`, `GAIN_DB`, `MUTED`, `SOLOED`) — so they restore with a
  session. They are deliberately *not* `AudioProcessorParameter`s (129 programs × 3 would be 387
  automatable parameters).
- Gain changes do **not** broadcast a change message (only the owning strip repaints); mute/solo do
  (the piano roll dims notes by audibility, the status bar recounts).
- `isAudible(program)` = not muted AND (nothing soloed among the *current* entries OR this is soloed).
- `resetStoredSettings()` removes the whole `INSTRUMENT_MIXER` subtree — called only when a
  transcription is launched, so a session reload keeps its mix.

---

## 5. Playback

### 5.1 Transport (`Player.cpp`, `SynthController.cpp`, `NoteScheduler.cpp`)
- Play/pause is a single toggle button; Back (`skipToStart`) stops and rewinds to 0 **and** scrolls the
  timeline viewport back to the left. There is **no loop** (the loop button is present but disabled).
- Playback is enabled whenever `canPlay()` — i.e. from the moment audio is loaded, including *during* a
  transcription. Only the part already decoded produces synth notes; past `finalizedThrough` the roll is
  empty and the synth silent.
- Seek: click anywhere on the waveform or the piano roll (`AudioRegion::mouseDown`,
  `PianoRoll::mouseDown`) → `Player::setPlayheadPositionSeconds`. The seek is ignored unless
  `0 <= t < audioDuration`.
- The playhead position is stored in the state tree (`PLAYHEAD_POSITION_SEC`) on save.
- End of audio: the playhead wraps to 0 in the source-playback path; `SynthController` additionally
  stops the transport and rewinds once `schedulerTime >= audioDuration`.
- `NoteScheduler` guarantees **every note-on is matched by a note-off** on both outputs. Key behaviours:
  - `MAX_ACTIVE_NOTES = 512` (also the polyphony ceiling; reaching it steals the oldest).
  - `MAX_LOOKBACK_SECONDS = 30` when re-anchoring sounding notes to a swapped list or re-attacking
    notes that cover the playhead after a seek/resume.
  - A swapped note list (which happens ~once per decoded chunk) re-anchors sounding notes instead of
    cutting them.
  - Note-offs are expired both before and after the onset pass, so a 10 ms drum hit inside one block is
    not stretched to the block length.
  - `SYNTH_EVENT_CAPACITY = 4 × 512`; the MidiBuffer is pre-sized to `16 × (2×512 + 128)` bytes.
  - Events are insertion-sorted (stable) so a note-off always precedes a note-on at the same offset.

### 5.2 Synth (`InstrumentSynth.cpp`, TinySoundFont)
- Soundfont: **MuseScore_General.sf3** (~38 MB), downloaded at configure time by
  `Tools/fetch_soundfont.py` from
  `https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf3`, pinned by
  SHA-256 `5b85b6c2...0b6fa3`, and compiled into the binary as its own BinaryData target
  (`SoundFontData`). Licence file `MuseScore_General_License.md` (MIT) is fetched alongside.
- Loaded **off the message thread** in a 1-thread pool at construction (~40 MB of Vorbis, >1 s on an
  M1 Pro). Until ready the synth renders silence; `TranscriptionManager` does exactly one catch-up pass
  once `isReady()` becomes true.
- **One `tsf` instance per instrument**, created by `tsf_copy` (shares sample data by refcount). tsf
  channels are not used at all — the preset index is resolved once and notes are triggered by preset.
- Preset lookup: melodic → `tsf_get_presetindex(font, bank 0, program)`; drums →
  `tsf_get_presetindex(font, bank 128, preset 0)` (GM Standard kit).
- Output mode `TSF_STEREO_UNWEAVED` at the device sample rate, global gain 0 dB.
- `tsf_set_max_voices(font, 32)` — **32 voices per instrument** (`MAX_VOICES_PER_INSTRUMENT`), pinning
  the pool so note-on never reallocates on the audio thread; an exhausted pool steals the quietest voice.
- Gain/mute/solo ramp: linear smoothing over **10 ms** (`GAIN_RAMP_SECONDS = 0.01`), for both the
  per-instrument and the master synth gain. Solo is derived per block (`audible = !muted && (!anySolo ||
  soloed)`), never stored as "the others are muted".
- Gain range **−36 dB (= silence, `MIN_INF_GAIN_DB`) … +6 dB (`MAX_GAIN_DB`)**, one shared pair of
  constants for every gain in the app.
- **Drum note-offs are deliberately ignored** by the synth (a GM kit is one-shot and a 10 ms note-off
  would choke every cymbal) — *except* for keys whose sample loops (`tsfExtrasGetLoopingKeys`); in the
  bundled font that is the open triangle and the bell tree. A stop or a seek instead calls
  `allNotesOff()` via a `mShouldSilenceSynth` flag consumed on the next block.
- Per-instrument rendering is skipped entirely when the instrument has no active voices and its fader
  is at rest (the meter is still advanced with silence).
- Mono output: the stereo mix is **folded** (L+R added into channel 0), not truncated.

### 5.3 Mix, master and output path (`Player::processBlock`, `Player::_setGains`)
- **Mix slider** (`MIX` parameter, 0…1, step 0.001, default **0.5**) is an **equal-power** crossfade:
  `angle = mix * π/2`, `sourceGain = cos(angle)`, `synthGain = sin(angle)` — both −3 dB at the midpoint.
  If the scheduler has no notes, `mix` is forced to 0 (all source), so the pill dims.
- **Master gain** (`MASTER_GAIN` parameter, −36…+6 dB, step 0.1, default **0 dB**) is applied as a ramp
  across the block, after the mix.
- Output buffer is sized `clamp(totalNumOutputChannels, 1, 2)`; the source is read with channel
  clamping (mono source → both outs) and ramped from the previous block's gain.
- The plugin's contribution is **added to** the host/device buffer (it passes the input through unless
  the `MUTE` parameter is on, which clears the buffer before the player runs).
- The master meter measures the plugin's own post-fader output only, not the pass-through.

---

## 6. MIDI export

### 6.1 Two exits
1. **Drag MIDI out** (`MidiFileDrag.cpp`): on mouse-down, writes the file into
   `<tempDir>/neuralnote/<name>` and hands it to `performExternalDragDropOfFiles({path}, false, this)`.
   The temp directory is **deleted recursively** when the component is destroyed. Cursor becomes a
   dragging hand on hover. The button's pressed state is manually reset after the nested drag loop.
2. **Export MIDI out** (`NnToolbar::_exportMidiFile`): a save dialog titled "Export MIDI", default
   directory = the user's **Music** folder, filter `*.mid`, overwrite warning on. Failure →
   "Error" / "Could not write the MIDI file."
- File name: `"<sourceFileNameWithoutExtension>_NNTranscription.mid"`, or `"NNTranscription.mid"` when
  the take was recorded (no dropped filename) (`NNFileUtils.cpp:119-126`).
- Both exits are **disabled unless state == `PopulatedAudioAndMidiRegions`** — a half-finished file
  gives no sign that it is one.

### 6.2 MIDI file format (`MidiFileWriter.cpp`)
- **960 ticks per quarter note** (`mTicksPerQuarterNote`).
- Multi-track (format 1, implied by `MidiFile::addTrack`). **Track 0 is a conductor track**: a tempo
  meta event (µs/qn = 1e6 × 60 / bpm, rounded) and a **4/4** time-signature meta event, both at tick 0.
  The model provides no meter, so 4/4 is a placeholder.
- Then **one track per instrument**, in ascending program order, each starting with
  a text meta event type **3** (track name) carrying the UI instrument name, and a **Program Change**
  at tick 0 (drums get program **0**, the standard kit; melodic instruments get their own program).
- `tick = (noteTime + startOffsetSeconds) * bpm / 60 * 960`.
- Velocity = `note.amplitude` = 100/127 for every note (JUCE converts the float to a 0-127 velocity).
- **Channel assignment** (`buildChannelMap`):
  - Channel **10** is reserved for drums **always**, even when the transcription has none.
  - 15 melodic channels: `1,2,3,4,5,6,7,8,9,11,12,13,14,15,16`, handed out in ascending program order
    (matching the sidebar).
  - Overflow past 15 melodic instruments is governed by `MIDI_OVERFLOW_MODE`
    (settings menu "MIDI export: too many instruments"):
    - `ReuseChannels` (**default**, 0): reuse starting at index 9 of the melodic list (i.e. channel 11)
      and cycling through the last 6 channels.
    - `DropExtraInstruments` (1): keep the 15 instruments with the most notes (ties broken by lower
      program), drop the rest entirely.
- Export tempo: the `EXPORT_TEMPO` state property, **default 120.0**, editable in the toolbar
  (validated to **20…999**, empty corrects to 120; max 6 characters; digits and "." only). It is
  overwritten by the host BPM when a take was recorded against a running transport. **[PLUGIN]**
- Start offset: `SourceAudioManager::getExportStartOffsetSeconds()` — non-zero only for a take recorded
  against a rolling host transport, so that MIDI time 0 lands on a bar line. **[PLUGIN]**
- The output stream is truncated before writing (so overwriting a longer file leaves no tail).

---

## 7. Piano roll & visualisation

### 7.1 Horizontal zoom / scroll (`CombinedAudioMidiRegion.cpp`)
- Base scale: **100 px per second** (`mBaseNumPixelsPerSecond`). Content width =
  `round(zoom × 100 × durationSeconds)`, never less than the viewport width.
- Zoom range **0.1 … 5.0**, but the lower bound is raised to "the audio exactly fills the viewport"
  (`viewportWidth / (100 × duration)`, itself clamped into [0.1, 5.0]) so you can never zoom out past
  the end of the take. Stored in the state as `ZOOM_LEVEL`, default 1.0.
- ⌘/Ctrl + wheel zooms (`zoom += wheel.deltaY`); pinch/magnify multiplies by the scale factor. Both keep
  the left edge of the view anchored in time.
- Plain wheel: **over the piano roll** a vertical wheel scrolls *pitch* (forwarded to the keyboard, which
  gives it sub-key precision); horizontal wheel scrolls time. Everywhere else the viewport handles it —
  unless the view is following the playhead during playback, where a scroll would be undone next frame.
- While recording, the view auto-scrolls to the far right on every change message.
- "Center playhead" (`PLAYHEAD_CENTERED`, default **true**, shortcut `c`): on every vblank during
  playback the viewport is positioned so the playhead sits at the horizontal centre
  (`CombinedAudioMidiRegion::_centerViewOnPlayhead`).

### 7.2 Vertical zoom & pitch range
- The zoom slider (status bar, 0…1) maps to a **per-semitone lane height** of
  `6.0 + norm × 37.6` px (`nn::zoom::rowHeightMin/rowHeightRange`), expressed to the keyboard as a
  white-key height of `rowHeight × 12/7` (`NnLook.h:326-347`).
- Stored as `VERTICAL_ZOOM`; **negative means "automatic"** — the zoom that exactly fits the
  transcription's octave span (`fitToContent`), never showing fewer than **12 semitones** (one octave).
  Moving the slider takes it off automatic; "Reset Zoom" puts it back (writes −1.0).
- Displayed pitch range (`PianoRollRange::computeDisplayRange`): whole octaves that (a) cover every
  transcribed note and (b) are never narrower than the key column, widened one octave at a time —
  **above first**, then alternating — so notes sit low in the view. Empty default is **C0…B5**
  (octaves 1..5 in the file's 0-based indexing), bounded by MIDI 0…127.
- While a transcription streams, the range may only **widen** (`unionOf` with what is on screen);
  every state change re-settles it so it can shrink.
- Keyboard: `KeyboardComponentBase`, vertical facing right, available range 0…127, black-note width
  proportion **0.58**, black-note length proportion **0.65**, default white-key height **11 px**
  (`pianoKeyHeight`). Scroll buttons are drawn as nothing and narrowed to 1 px (turning them off would
  pin the view). Zooming keeps the centre note fixed.
- Key drawing: white keys `keyWhite` with a 1 px gap on the bottom and right edges (the gap *is* the
  divider — there are no key outlines); black keys `keyBlack` with a 1 px bottom gap; every C is
  labelled `"C<octave>"` in `scaleLabel()` (mono 7.5), colour `keyLabel`, right-aligned with a 5 px
  inset. With no notes the whole key column is blended 40 % toward `bgGutter` ("dimmed").
- Gutter (46 px, `TimelineGutter.cpp`): `bgGutter` fill, right border `divStrong`, bottom borders
  `divSoft`; amplitude labels "+1.0" / "0" / "−1.0" (U+2212 minus) in `scaleLabel()`, each **centred on
  the exact y its amplitude maps to** — `waveformCentreY = 126/2 + 0.5 = 63.5`,
  `waveformAmpHalfSpan = 51.0`. The ruler's share of the gutter is deliberately empty.

### 7.3 Waveform (`AudioRegion.cpp`)
- Background `bgPanel`, bottom border `divSoft`; a white @5 % centre line at `height/2`.
- Bars: width **3 px**, gap **1 px**, pitch **4 px** (`nn::metrics::waveformBar*`). Bars are anchored to
  *absolute content pixels*, not the visible window, so scrolling reveals rather than re-slices
  (`WaveformBars.h`). Only bars inside the current clip rectangle are drawn (the component can be
  hundreds of thousands of pixels wide).
- Each bar spans its full pitch of audio (no sample is unrepresented). Default **symmetric** drawing:
  the bar is mirrored about the centre at `max(|min|,|max|)`; minimum height **1 px**. The scale is
  absolute (amplitude 1.0 = the gutter's "+1.0"), so quiet audio draws quietly.
- Played region: everything left of the playhead is washed with `accentWashWave` (accent @4.5 %) and a
  1 px `accentWashEdge` line at the playhead.
- Corner label "MIX WAVEFORM" in `meta()` at inset 10, tracking 0.1, colour `textScale`.
- **Empty state**: a dashed rounded panel (inset 9, corner 8, dash pattern 4/4, 1 px stroke,
  border `dropZoneBorder` / fill `dropZoneFill`; both switch to `ctaBorder`/`ctaFill` while a file is
  dragged over), a centred "Load audio file" button (folder icon 14 px, height 32, padding 15, gap 8,
  accent outline, `accentFillButton` background) and the hint "OR DROP A FILE HERE"
  (`meta()`, tracking 0.06, 12 px tall, 9 px below the button).
- Playhead repaint is incremental: only the swept sliver (±2 px) is repainted per vblank.

### 7.4 Time ruler (`TimeRuler.cpp`)
- Absolute **seconds only** — no bars/beats anywhere in the UI; the only tempo in the app is the MIDI
  export tempo.
- Tick divisions chosen from `{0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60}` s — the first whose pixel
  spacing is ≥ **56 px** (`MIN_LABEL_GAP`).
- 1 px full-height tick in `divTick`, label `"m:ss"` (seconds zero-padded to 2) in `meta()`,
  `textFaint`, 6 px to the right of the tick.
- Background `bgPanel`, bottom border `divSoft`. Nothing is drawn unless `canPlay()`.

### 7.5 Piano roll (`PianoRoll.cpp`)
- Background `bgRoot`. Nothing drawn unless `canPlay()`.
- **Lanes**: one per semitone in the displayed range, `laneWhite` / `laneBlack` by key colour,
  at alpha **0.55** while there are no notes. A 1 px `divOctave` separator under every C.
  Lane geometry is measured off the keyboard component, so the two can never disagree.
- **Notes**: rounded rectangles, corner **2**, colour = the instrument's colour, width =
  `max(1, x(end) − x(start) − 1)`. Audible instruments at full alpha; muted/un-soloed at
  `MUTED_NOTE_ALPHA` **0.16**. **No velocity shading** (the model emits none).
  A **2 px onset edge** in white @35 % is drawn at the left of any note wider than 4 px, so repeated
  notes at one pitch do not read as one long note.
  Drum hits are drawn at a minimum of **0.1 s** (`DRUM_MIN_DRAWN_SECONDS`) even though their real
  duration is 10 ms; the exported note keeps the real offset.
- **Playhead**: a 1 px `textBright` vertical line; the waveform's copy also draws a 9 px equilateral
  triangle marker at the top (height = √3/2 × 9 ≈ 7.79); the ruler's and the roll's do not. Everything
  left of it in the roll is washed with `accentWashRoll` (accent @3 %). Hidden while the state is
  `AudioLoaded` or `Empty` (so it does not sweep across the Transcribe button).
- **Transcription frontier**: while `Processing`, everything right of `finalizedThrough` is covered with
  `bgRoot @75 %` plus a 1 px `divStrong` vertical line.
- **No note editing, no selection, no dragging of notes.** The only mouse interaction on the roll is
  click-to-seek.

---

## 8. Settings / persistence

### 8.1 Global settings (`NnGlobalSettings.cpp`, `NNFileUtils.cpp`)
- File: `<userApplicationData>/NeuralNote/global.settings` → macOS `~/Library/NeuralNote/global.settings`.
  XML format (`PropertiesFile::storeAsXML`), guarded by `InterProcessLock("NeuralNoteGlobalSettings")`,
  saved explicitly (never auto-saved: `millisecondsBeforeSaving = -1`).
- Keys and defaults:
  | key | type | default |
  |---|---|---|
  | `modelSize` | "small"/"medium"/"large" | `medium` |
  | `editorScale` | double | `1.0` |
  | `tooltipsVisible` | bool | `true` |
- Any setter rewrites **all three** keys, so the file always lists what the app is using. Reloaded once
  per editor open, so a second window picks up outside changes.

### 8.2 Per-instance / session state (`NnId.h`, `PluginProcessor.cpp`)
Saved as XML inside `NEURAL_NOTE_FULL_STATE` → `{ NEURAL_NOTE_VERSION, PARAMETERS (APVTS),
NEURAL_NOTE_STATE }`. **[PLUGIN]** for DAW sessions; the standalone also uses this path through JUCE's
standalone wrapper (inferred).

| property | default |
|---|---|
| `EXPORT_TEMPO` | 120.0 |
| `MIDI_OVERFLOW_MODE` | 0 (ReuseChannels) |
| `SOURCE_AUDIO_NATIVE_SR_PATH` | "" |
| `PLAYHEAD_POSITION_SEC` | 0.0 |
| `PLAYHEAD_CENTERED` | true |
| `ZOOM_LEVEL` | 1.0 |
| `VERTICAL_ZOOM` | −1.0 (automatic) |
| `SELECTED_INSTRUMENT_GROUPS` | "" (Automatic) |
| child `INSTRUMENT_MIXER` | absent |

- `SOURCE_AUDIO_NATIVE_SR_PATH` is a **path**, not the audio: reloading a session re-reads the file from
  disk (a recording from `~/Library/NeuralNote/recordings/`, or the user's dropped file wherever it is).
  If the path is a recording, the matching `_downsampled.wav` is registered for deletion on clear.
  **The transcription itself is NOT saved** — reloading a session gives you the audio back, not the notes.
- `MIDI_OUT` and `NEURAL_NOTE_VERSION` identifiers exist; `MIDI_OUT` is read by `Player` but is not in
  the ordered-default list and has no UI, so MIDI output to the host is effectively **off by default**
  and unreachable in this build (inferred — "MIDI out, with per-instrument channel selection" is on the
  README roadmap).
- Restoring: only the listed properties are copied (extras ignored, missing ones left at their current
  value); the `INSTRUMENT_MIXER` child is replaced wholesale.

### 8.3 Other filesystem locations (`NNFileUtils.h`)
- `<appdata>/NeuralNote/` — root
- `<appdata>/NeuralNote/models/` — checkpoints
- `<appdata>/NeuralNote/recordings/` — recorded WAVs (prefix `recorded_audio`)
- `<appdata>/NeuralNote/global.settings`
- `<temp>/neuralnote/` — MIDI drag scratch, deleted recursively on editor teardown
- default MIDI export directory = the user's **Music** folder
- (disabled in this build) log file `/tmp/NeuralNote/log.txt` via `FileLogger`, behind `#if 0`
  (`PluginProcessor.cpp:8-11`).

---

## 9. Update check (`UpdateCheck.cpp`)

- Checked **once per editor open** (`checkForUpdate(false)` from `NeuralNoteMainView`'s constructor),
  and on demand from Settings → "Check for updates" (`checkForUpdate(true)`).
- Endpoint: `https://api.github.com/repos/DamRsn/NeuralNote/releases/latest`, parsed as JSON, field
  `tag_name`. Run on a detached `Thread::launch`, hopping back to the message thread with
  `SafePointer` guards. Empty response = silent no-op.
- Version comparison: dotted numeric, leading "v"/"V" stripped, missing components count as 0.
- Notification panel (bottom-right, above the status bar): text
  `"A new version of NeuralNote is available"` or `"You are on the latest version of NeuralNote"`
  (the latter only when the check was explicitly requested), drawn on the standard popup surface,
  `menuItem()` font, sized to its content (2 × 11 padding + text + 9 gap + 16 cross, plus the button).
- When an update exists it also shows a **"See update"** button (accent-outlined, height 24, padding 12)
  opening `https://github.com/DamRsn/NeuralNote/releases/latest` in the default browser.
- Auto-dismiss after **10 s**, extended to **now + 3 s** on every 5 Hz tick while the pointer is over it;
  a cross dismisses it immediately. `hitTest` is restricted to the panel so the empty area does not
  swallow clicks meant for the piano roll.

---

## 10. Plugin-specific behaviour **[PLUGIN]**

- **Formats**: AU, VST3, Standalone. `IS_SYNTH=FALSE`, `NEEDS_MIDI_INPUT=FALSE`,
  `NEEDS_MIDI_OUTPUT=TRUE`, `IS_MIDI_EFFECT=FALSE`, `EDITOR_WANTS_KEYBOARD_FOCUS=FALSE`,
  `MICROPHONE_PERMISSION_ENABLED=TRUE` with text "Need access to Microphone",
  `HARDENED_RUNTIME_ENABLED=TRUE`, `JUCE_VST3_CAN_REPLACE_VST2=0`, `JUCE_WEB_BROWSER=0`,
  `JUCE_USE_CURL` only on Linux, `JUCE_ASIO=1` on Windows.
- **Buses**: stereo in / stereo out by default; mono and stereo are both accepted but the input layout
  must equal the output layout (`ProcessorBase.cpp:100-117`).
- **Automatable parameters** (only three — `ParameterHelpers.h`):
  | id | name | type | range | default | AU version hint |
  |---|---|---|---|---|---|
  | `MUTE` | Mute | bool | — | false | 2 |
  | `MIX` | Mix | float | 0…1, step 0.001 | 0.5 | 3 |
  | `MASTER_GAIN` | Master Gain | float | −36…+6 dB, step 0.1 | 0.0 | 3 |
  Version hints must not change: JUCE orders the AU parameter list by them and Logic/GarageBand key
  saved automation off that order.
- **Latency**: never reported — `setLatencySamples` is never called; `getTailLengthSeconds()` returns 0.
- `MUTE` clears the incoming buffer before the player's own output is added, i.e. it mutes the host's
  pass-through, not the plugin's synth.
- **Recording in a DAW** captures whatever the host feeds the plugin's input bus, and additionally reads
  the host timeline to compute the export bar offset and the export tempo (see §2.1). In the standalone
  there is no playhead, so both stay 0 and the export tempo stays whatever the user typed.
- **MIDI output**: the `NoteScheduler` already produces a `MidiBuffer` (all notes flattened onto
  **channel 1**, with per-pitch reference counting so two instruments on one pitch open it once), and
  `Player` will forward it to the host when `MIDI_OUT` is true — including a clean set of note-offs when
  MIDI out is switched off mid-note. There is no UI for `MIDI_OUT` in this build.
- **Resizing**: `NnEditorConstrainer` is installed via `setConstrainer`, so the host's own resize
  negotiation is capped. Its `resizeEnd` (and therefore scale persistence) fires in a host but not in
  the standalone, whose window wraps the constrainer in JUCE's `DecoratorConstrainer`.
- `SharedResourcePointer` is used for the LookAndFeel and the ModelDownloader so multiple instances in
  one host share one default look and one download per size.
- One `InterProcessLock` per model size keeps a standalone next to a host (or out-of-process plugins)
  from downloading the same checkpoint twice.

---

## 11. Anything else

### 11.1 Application states (`PluginProcessor.h:27`)
`EmptyAudioAndMidiRegions → Recording → AudioLoaded → Processing → PopulatedAudioAndMidiRegions`.
- `canPlay()` = AudioLoaded | Processing | Populated.
- `hasTranscription()` = Processing | Populated.
- Cancel/failure returns to `AudioLoaded` (or `Empty` if there was no audio).

### 11.2 Keyboard shortcuts (`NeuralNoteMainView::keyPressed`, tooltips)
| key | action |
|---|---|
| `Space` | Play / Pause |
| `Shift + Space` | Go to start |
| `Shift + Backspace` | Clear audio *and* transcription (only in `AudioLoaded` or `Populated`) |
| `r` | Record toggle |
| `m` | Mute input toggle |
| `c` | Centre playhead toggle |
| `Esc` | Close the instrument picker |
| Right-click on the bin | Clear menu ("Clear audio and transcription" / "Clear transcription only") |
| ⌘/Ctrl + wheel, pinch | Horizontal zoom |
| Double-click a fader | Reset to 0.0 dB |

### 11.3 Settings menu (`NeuralNoteMainView::_buildSettingsMenu`)
1. **Reset Zoom** — `ZOOM_LEVEL = 1.0`, `VERTICAL_ZOOM = −1.0` (back to automatic).
2. **Show Tooltips** (tickable, persisted in `global.settings`).
3. **MIDI export: too many instruments** ▸ "Reuse the last channels" / "Drop the extra instruments".
4. **Window size** ▸ 50 % / 75 % / 100 % / 125 % / 150 % / 200 %.
5. — separator —
6. **Check for updates**.
Tick and enablement states are re-evaluated every time the menu opens (so another instance's changes
show up). Nothing is drawn for an unticked row, because some rows are actions rather than toggles.

### 11.4 Tooltips (`NeuralNoteTooltips.h`)
Exact strings:
- record: `"Record | r"`
- clear: `"Clear audio and transcription | Shift + Backspace\nRight-click to clear the transcription only"`
- play/pause: `"Play / Pause | Space"`
- back: `"Go to start | Shift + Space"`
- centre: `"Center playhead | c"`
- settings: `"Settings"`
- mute: `"Mute / Unmute input | m"`
- cancel transcription: `"Cancel transcription"`
- model: `"Choose the transcription model, or download another"`
- stop download: `"Stop the download. Starting it again resumes where it stopped"`
- transcribe: `"Transcribe the loaded audio"`
- load audio: `"Load an audio file"`
- add instrument: `"Restrict the transcription to chosen instruments"`
- export tempo: `"Set export tempo for midi file"`
- source audio level: `"Set source audio level"` / internal synth level: `"Set internal synth level"`
  (both currently unused; the top bar uses `"Balance between the source audio and the synthesised
  transcription"` and `"Output level"`)
- Others set inline: `"Loop (not implemented yet)"`, `"Write the transcribed MIDI to a file"`,
  `"Drag the transcribed MIDI into your DAW"`, `"Piano roll vertical zoom"`, `"Mute this instrument"`,
  `"Solo this instrument"`, `"Level for this instrument"`, `"Close"`, `"Dismiss"`.

### 11.5 Timers, vblank callbacks and refresh rates
| what | rate | file |
|---|---|---|
| `TranscriptionManager` drain/apply | 30 Hz timer | `TranscriptionManager.cpp:19` |
| `NeuralNoteMainView` state/transport sync | 20 Hz timer | `NeuralNoteMainView.cpp:77` |
| `ModelDownloadPanel` poll | 10 Hz timer | `ModelDownloadPanel.cpp:49,157` |
| `UpdateCheck` auto-hide | 5 Hz timer | `UpdateCheck.cpp:194` |
| Sidebar meters (all strips + master) | vblank | `Sidebar.h:102` |
| Playhead, waveform, piano roll, time display, transcription progress | vblank, each repainting only what changed | `Playhead.cpp`, `AudioRegion.cpp`, `PianoRoll.cpp`, `TimeDisplay.cpp`, `TranscriptionProgress.cpp` |
| Tooltip delay | 800 ms | `NeuralNoteMainView.cpp:342` |

### 11.6 Threading model
- **Audio thread**: `SourceAudioManager::processBlock` (writes to two threaded-writer FIFOs, runs the
  resampler), `NoteScheduler::renderNextBlock`, `InstrumentSynth::processBlock`, `Player::processBlock`,
  meter pushes. Allocation-free by construction (pre-sized MidiBuffer, pinned voice pool, reserved
  event vector).
- **Message thread**: all UI, all `ValueTree` access, post-processing, `InstrumentSynth::ensureInstrument`
  and `reset` (both taken **under the processor's callback lock**), `NnGlobalSettings`.
- **Transcription**: a single-thread `ThreadPool`; the engine stages notes under a mutex and publishes
  progress/outcome through atomics.
- **Soundfont load**: its own 1-thread pool; `mFontReady` is release-stored.
- **Downloads**: one `juce::Thread` per model size.
- **Writers**: two `TimeSliceThread`s (native-rate and downsampled).
- **Update check**: a detached `Thread::launch` plus `MessageManager::callAsync` hops.

### 11.7 Error dialogs (all `NativeMessageBox::showMessageBoxAsync`, icon `NoIcon`)
- "Error" / "File creation for recording failed."
- "Could not load the recorded audio sample." (empty body)
- "Could not load the audio file." / "Check your file format (Accepted formats: .wav, .aiff, .flac, .mp3, .ogg)."
- "Could not load the file." / "Check your file format (Accepted formats: <joined list>)."
- "Transcription failed." / "The transcription model could not be loaded or run[: <reason>]."
- "Error" / "Could not write the MIDI file."
- "Error" / "Temporary directory for midi file failed."
- "Error" / "Could not create the midi file."

### 11.8 Menus / about box / links
- There is **no About box** and no menu bar of the app's own. The standalone gets JUCE's stock
  "Options" button, audio/MIDI settings dialog and window frame, recoloured through the LookAndFeel.
- Links: GitHub releases page (update notification), GitHub API (update check), Hugging Face
  (model downloads). Nothing else goes online; audio never leaves the machine.
- Licence text ships in `Installers/license.txt` (Apache-2.0 for NeuralNote's code, plus third-party
  notices for JUCE, muscriptor.cpp, ggml, PFFFT, TinySoundFont, MuseScore_General, minimp3, Inter,
  JetBrains Mono). **Model weights are CC BY-NC 4.0 — non-commercial use only.**

### 11.9 Animations
- Transcription caption pulse (1.6 s raised cosine, 0.55…1.0).
- Meter release (24 dB/s, instant attack).
- Gain/mute/solo 10 ms linear ramps in the synth; source and master gains ramped per block.
- Nothing else animates; hover/press states are instantaneous colour swaps.

---

## Third-party pieces the Swift app could link directly

### muscriptor.cpp — public API (`ThirdParty/muscriptor.cpp/cpp/include/muscriptor/`)
Namespace `msl`. Requires C++23 (so a C or Objective-C++ shim is needed to reach it from Swift —
`std::expected` and `std::span` do not bridge). Include `muscriptor/muscriptor.hpp`.

**`error.hpp`**
```c++
enum class Error { FileNotFound, InvalidCheckpoint, UnsupportedArch,
                   UnsupportedCheckpointVersion, OutOfMemory, ContextOverflow,
                   Cancelled, InvalidArgument, Internal };
const char* describe(Error inError);
class Exception : public std::runtime_error {
public:
    Exception(Error inError, const std::string& inMessage);
    Error error() const;
};
```

**`note.hpp`**
```c++
enum class InstrumentGroup : std::int32_t {
    AcousticPiano=0, ElectricPiano=1, ChromaticPercussion=2, Organ=3, AcousticGuitar=4,
    CleanElectricGuitar=5, DistortedElectricGuitar=6, AcousticBass=7, ElectricBass=8, Violin=9,
    Viola=10, Cello=11, Contrabass=12, OrchestralHarp=13, Timpani=14, StringEnsemble=15,
    SynthStrings=16, Voice=17, OrchestraHit=18, Trumpet=19, Trombone=20, Tuba=21, FrenchHorn=22,
    BrassSection=23, SopranoAndAltoSax=24, TenorSax=25, BaritoneSax=26, Oboe=27, EnglishHorn=28,
    Bassoon=29, Clarinet=30, Flutes=31, SynthLead=32, SynthPad=33, Drums=36 };

inline constexpr int    DRUM_PROGRAM = 128;
inline constexpr double MINIMUM_NOTE_DURATION_SECONDS = 0.01;

struct Note { double onset = 0.0; double offset = 0.0; int pitch = 0; int program = 0;
              bool is_drum = false; };

std::span<const InstrumentGroup> allInstrumentGroups();
std::optional<InstrumentGroup>   instrumentGroupFor(int inProgram);
std::string_view                 instrumentName(InstrumentGroup inGroup);
int                              programFor(InstrumentGroup inGroup);
std::string                      instrumentLabel(int inProgram);
```

**`transcriber.hpp`**
```c++
struct TranscribeOptions { std::vector<InstrumentGroup> instruments;   // empty = unconditional
                           bool prelude_forcing = true;
                           int  n_threads = 0; };                      // 0 = performance cores
struct LoadOptions       { bool use_gpu = true; };
struct TranscriptionUpdate { std::span<const Note> new_notes;
                             double finalized_through = 0.0;
                             float  progress = 0.0f; };
using NoteCallback = std::function<bool(const TranscriptionUpdate& inUpdate)>;  // false cancels

inline constexpr int CHECKPOINT_FORMAT_VERSION = 1;

class Transcriber {
public:
    static constexpr int    SAMPLE_RATE          = 16000;
    static constexpr int    SEGMENT_SAMPLES      = 80000;
    static constexpr double SEGMENT_DURATION     = 5.0;
    static constexpr int    MAX_TOKENS_PER_CHUNK = 2000;

    static std::expected<Transcriber, Error> load(const std::filesystem::path& inGgufPath,
                                                  LoadOptions inOptions = {});
    const char* backendName() const;                 // "CPU" | "Metal" | "Vulkan"
    std::expected<std::vector<Note>, Error> transcribe(std::span<const float> inSamples,
                                                       const TranscribeOptions& inOptions = {},
                                                       const NoteCallback& inCallback = {});
    static int chunkCount(std::size_t inNSamples);
    Transcriber(Transcriber&&) noexcept;  Transcriber& operator=(Transcriber&&) noexcept;
    Transcriber(const Transcriber&) = delete;  Transcriber& operator=(const Transcriber&) = delete;
    ~Transcriber();
};
```
Semantics that matter: 16 kHz mono float32 for the whole signal, split into 5 s chunks (last one
zero-padded); blocking, seconds to minutes, never on an audio thread; one `transcribe` at a time per
instance (it mutates the KV cache and is not synchronised); result sorted by
`(onset, is_drum, program, pitch, offset)`; the callback fires synchronously on the calling thread, once
per chunk and once more at the end, with notes released one chunk late and valid only for the call;
`finalized_through` after chunk *k* is `k × 5 s`; CPU and GPU results are not bit-identical.
Chunks that never emit EOS are not errors.

**`log.hpp`**
```c++
enum class LogLevel { Off, Error, Warn, Info, Debug };
using LogCallback = std::function<void(LogLevel inLevel, std::string_view inText)>;
void setLogCallback(LogCallback inCallback, LogLevel inMaxLevel = LogLevel::Warn);
```
Process-global, not synchronised; install it before loading a model. The library emits nothing itself
(these are ggml's messages); ggml's Vulkan backend still writes some errors straight to `std::cerr`.

**`model.hpp`** is the layer below `Transcriber` (`Hparams`, `ModelOptions{n_ctx=2560, n_threads=0,
use_gpu=true}`, `Model::load/prefill/decode/generate/encodeAudio/encodeConditioning/reset/
setInstrumentRows/setForbiddenTokens/positionEmbeddings/nPast/contextSize/graphNodeCount`).
NeuralNote does **not** use it; a Swift port should not either.

### TinySoundFont (`ThirdParty/TinySoundFont/tsf.h`) — C API, bridges to Swift directly
Only the parts NeuralNote uses, plus the near neighbours:
```c
tsf*  tsf_load_memory(const void* buffer, int size);
tsf*  tsf_load_filename(const char* filename);
tsf*  tsf_copy(tsf* f);                 // shares sample data by refcount
void  tsf_close(tsf* f);
void  tsf_reset(tsf* f);

int   tsf_get_presetindex(const tsf* f, int bank, int preset_number);
int   tsf_get_presetcount(const tsf* f);
const char* tsf_get_presetname(const tsf* f, int preset_index);
const char* tsf_bank_get_presetname(const tsf* f, int bank, int preset_number);

enum TSFOutputMode { TSF_STEREO_INTERLEAVED, TSF_STEREO_UNWEAVED, TSF_MONO };
void  tsf_set_output(tsf* f, enum TSFOutputMode mode, int samplerate, float global_gain_db);
void  tsf_set_volume(tsf* f, float global_gain);
int   tsf_set_max_voices(tsf* f, int max_voices);

int   tsf_note_on (tsf* f, int preset_index, int key, float vel);   // vel 0..1
void  tsf_note_off(tsf* f, int preset_index, int key);
void  tsf_note_off_all(tsf* f);
int   tsf_active_voice_count(tsf* f);

void  tsf_render_float(tsf* f, float* buffer, int samples, int flag_mixing);
void  tsf_render_short(tsf* f, short* buffer, int samples, int flag_mixing);
```
`TSF_STEREO_UNWEAVED` writes the whole left channel then the whole right (`right = left + numSamples`).
There is also a full channel API (`tsf_channel_set_presetnumber`, `tsf_channel_note_on`, pan, volume,
pitch wheel, CC…) that NeuralNote deliberately does **not** use — one `tsf` per instrument, triggered by
preset index.

Project-local extra (`tsf_extras.h`, implemented in `tsf_impl.cpp` because it needs tsf's internal
structs):
```c
void tsfExtrasGetLoopingKeys(const tsf* inFont, int inPresetIndex, bool* outKeys /* 128 entries */);
```
Reports which MIDI keys of a preset have a looping sample region — needed because NeuralNote suppresses
note-offs for one-shot GM percussion but must not suppress them for looping keys (open triangle, bell
tree in this font), which would otherwise sound forever and never return their voice.

### Other bundled libraries
- **minimp3** (CC0) — `mp3dec_t` / `mp3dec_file_info_t` / `mp3dec_load(&dec, path, &info, nullptr,
  nullptr)`; interleaved `short` samples scaled by 1/32768. On macOS, `AVAudioFile` / `AudioToolbox`
  covers MP3 natively, so this is replaceable.
- **JUCE** — audio device handling, file formats, resampling (`LagrangeInterpolator` +
  `dsp::FilterDesign::designIIRLowpassHighOrderButterworthMethod`), `WebInputStream`, `SHA256`,
  `PropertiesFile`, `MidiFile`. All of these have straightforward AVFoundation / Accelerate /
  Foundation / CryptoKit equivalents on macOS.
- **ggml** — fetched transitively by muscriptor.cpp; not touched directly.
