# Native chrome and light mode — Design

NeuralSheet's window is still NeuralNote's: a fixed dark palette written in sRGB constants, Inter
and JetBrains Mono at 7.5–12.5 pt with tracked capitals, and five stacked bars (the title bar, the
top bar, the tab strip, the toolbar and the status bar: 184 px of an 800 px window) before the
piano roll. It does not look like a Mac app and it has no light mode. On a Mac set to Light the
title bar, Settings and the alerts already turn light while the content stays dark.

This change rebuilds the window's chrome from SwiftUI's own pieces, the way a macOS 26 app is
built, and gives the whole app a light appearance beside the dark one. It is direction B of the
design review canvas (October 2026): a unified toolbar, a floating glass sidebar, a standard
inspector on the right and a floating transport over the roll. The timeline, the score and the
cards keep their drawing and their behaviour; they take the palette of the appearance they are
drawn in.

Everything this does not mention is unchanged.

## 1. Goals and non-goals

Goals

- A light and a dark appearance for every surface the Mac app draws, chosen by the system or by
  Settings → General → Appearance (System, Light, Dark).
- One palette with two sides: every `Theme` colour has a dark value (today's) and a light value,
  and both have an Increase Contrast twin. The AppKit views repaint when the appearance changes.
- The chrome in the system font at macOS sizes, in sentence case, with native controls wherever
  SwiftUI has one: segmented pickers, menus, sliders, toggles, the toolbar's overflow.
- Less chrome: one 52 px toolbar replaces the top bar, the tab strip, the three toolbar rows and
  the status bar.
- Nothing lost: every control and figure the old bars carried has a place (§4).

Non-goals

- The iOS app and the Audio Unit. They share `Theme`, `Fonts` and the timeline drawing; they stay
  dark (the appearance flag defaults to dark and only the Mac app sets it) and keep their fonts.
- The timeline's drawn labels (ruler, keyboard, chord lane). They keep JetBrains Mono, which the
  iOS app and the Audio Unit draw them in too.
- The PDF and the printed score: paper is white in both appearances already.
- Following the system accent colour. The accent stays the app's blue, a shade per appearance.

## 2. Decisions

| Question | Decision |
|---|---|
| Who decides the appearance | `GlobalSettings.appearance`: `.system` (default), `.light`, `.dark`, applied as `NSApp.appearance` (nil, `.aqua`, `.darkAqua`). The palette follows `NSApp.effectiveAppearance`, so System tracks the Mac's setting live. |
| How the palette switches | `ThemeAppearance.shared.isDark`, an observable flag in `Theme.swift`, true unless the Mac app says otherwise. Every `Theme` colour reads it, so a SwiftUI body using one is drawn again when it flips; `TimelinePalette` keeps one resolved set per appearance and contrast. The change posts `Accommodations.didChange`, the repaint the timeline already listens for. |
| Light values | The same roles as the dark ones: white lanes with a cool grey for the black keys' lanes, `#F5F5F7` panels, black text at 86 % and secondary text that passes 4.5:1. Instrument colours keep their hue and drop in lightness so a note reads on a white lane (§3). |
| Type | The chrome uses the system font: 13 pt for controls and body, 11 pt for secondary text, 10 pt at the smallest, figures in `.monospacedDigit()`. No tracked capitals in the chrome. `Fonts` keeps the bundled faces for the drawn timeline. |
| Window | A `NavigationSplitView`: the sidebar (instruments and the mix) and the detail (the timeline or the score) with an `.inspector` on its right. The unified toolbar carries the title and the controls; the old top bar, tab strip, toolbar rows and status bar are gone. |
| Tabs | A segmented `Picker` in the toolbar's principal place: Transcribe, Edit, Score; Edit and Score disabled until there is a transcription, ⌘1/⌘2/⌘3 as before. |
| Title | `navigationTitle` is the project's title; `navigationSubtitle` is what the status bar said: the model, the instrument and note counts, the range, the length, and the comparison while a version is shown. |
| Transport | A floating glass capsule centred over the bottom of the timeline: go to start, play / pause, record, loop, follow, the time, and the speed as a menu of 50…150 %. The count-in's beats to go replace the time while it runs. |
| Progress | A run's progress and the stems export's take the capsule's trailing end while they run, as they took the status bar's. |
| Vertical zoom | A small glass capsule at the roll's bottom-right corner: the zoom icon and the slider, as the status bar had them. |
| Inspector | On the right, shown by default, toggled from the toolbar and ⌥⌘I. Edit: Selection (the fields the SELECTION panel had), then Grid, then Key. Score: Grid and Key. Transcribe: Grid and Key, read-only until there is a take. |
| Menus | The toolbar's menus (division, tonic, mode, parts, page size, the bin's choices) are native `Menu`s. The floating cards (note, chord, marker, tempo, instrument, sheet) stay `PopupMenuPresenter` panels, drawn in the palette. |
| Tooltips | The custom tooltip and its Show tooltips switch stay; native controls get `.help` only through it, so the switch keeps working. |

## 3. Palette

Every token in `Theme` keeps its name and its dark value. The light value takes the role, not the
arithmetic:

- Surfaces: `bgRoot` and `bgPanel` `#FFFFFF`; `bgTopBar`, `bgSidebar` and `bgGutter` `#F5F5F7`;
  the control fills `#FFFFFF`…`#E8E8ED`, pressed a step darker.
- Dividers: black at 10–16 %, as `separatorColor` is.
- Text: `#1D1D1F` for the primary roles, `#3C3C43` at 75 % for the secondary ones, and the faint
  roles no lighter than 3:1 on white; under Increase Contrast every text role is at least 7:1.
- Accent `#007AFF` (text `#0063CC`); record `#FF3B30`; warn `#C76A00`; the meters green, yellow,
  orange of the system.
- The roll: lanes `#FFFFFF` and `#F2F2F5`, keys white and `#2C2C2E`, waveform `#636366` played and
  `#C7C7CC` unplayed, the onset edge black at 25 %.
- Instrument colours: the dark side is the palette as it is. The light side is the same hue with
  its lightness clamped to 0.62 (HSL), computed in `Theme.noteColour(_:)`, plus a 0.5 px edge at
  black 22 %. The colours the model and the files carry are unchanged.

## 4. Where everything went

| Was | Now |
|---|---|
| Top bar: transport, time, SPEED | The transport capsule. |
| Tab strip | The toolbar's segmented picker. |
| Transcribe toolbar: file name, Stems, Re-transcribe, bin | The title; toolbar items Stems (toggle), Re-transcribe, Clear (a menu: everything, or the transcription only). |
| Edit toolbar: tools, snap, division, swing, tempo, time, beat 1, Tap, Detect, key, Quantize, Re-transcribe, Undo / Redo, MIDI | Toolbar: tools (segmented), Snap with the division menu, Quantize, Re-transcribe, Undo / Redo, MIDI. Inspector → Grid: tempo, time, beat 1 at with set-from-playhead, swing, Tap, Detect. Inspector → Key: tonic, mode. |
| Score toolbar: Continuous / Pages, A4 / Letter, Parts, grid, key, Sheet…, Export PDF, MIDI | Toolbar: layout (segmented), page size menu, Parts menu, Sheet…, Export PDF, MIDI. Inspector: Grid and Key. |
| Sidebar header INSTRUMENTS, count, + | The sidebar's "Instruments" section header with its + button. |
| Instrument strips | The same strip, restyled: colour dot with the abbreviation, name and counts, mute and solo, fader and readout, meter and pan. |
| SELECTION panel | Inspector → Selection. |
| Master panel: meter, ORIG / MIDI with holds, split, output, MUTE, CLICK and its level | The sidebar's "Mix" section at the bottom: the meter, Original – MIDI with the holds, Stereo split, Output with Mute, Click with its level. |
| Status bar figures | The window's subtitle. |
| Status bar progress | The transport capsule's trailing end. |
| Status bar vertical zoom | The roll's corner capsule. |

## 5. Implementation order

Each step builds, passes the tests and is committed on its own, on `redesign/native-chrome`:

1. `core:` `GlobalSettings.appearance`, with its tests.
2. `ui:` the two-sided palette, `ThemeAppearance`, `TimelinePalette` per appearance, the repaint,
   the score's screen paper; `app:` the appearance applied and Settings → General → Appearance.
3. `ui:` the chrome in the system font and sentence case.
4. `ui:` the window: split view, toolbar, inspector, transport capsule, zoom capsule; the old bars
   removed.
5. `docs:` CLAUDE.md's departures, the changelog, the inventory-citing comments.

## 6. Testing

- `swift test` for the setting's coding and its fallback.
- The build warning-free; the localization check passing with German and Spanish for every new
  string.
- By hand, in both appearances and with Increase Contrast: the empty window, a take, a run in
  flight, the Edit tab with a selection, the Score tab in both layouts, the welcome window,
  Settings, every card. VoiceOver reaches every toolbar item, the transport and the inspector.
