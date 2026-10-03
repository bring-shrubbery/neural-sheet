# Accessibility and localization — Design

Spec: [issue #25](https://github.com/bring-shrubbery/neural-sheet/issues/25).

The SwiftUI side has thirteen accessibility modifiers and the twelve custom `NSView`s have none;
no string is localized. This is a pass over the whole UI: labels and containers for VoiceOver,
full keyboard access, the four system accommodations, then every string into a String Catalog
with German and Spanish filled in.

Everything this document does not mention is unchanged. **No visual change for a user with
default settings: this work is invisible unless an accommodation is on or the language is set.**

## 1. Goals and non-goals

Goals

- Audit-clean accessibility; a readable, operable roll and score under VoiceOver; keyboard
  reachability; contrast / transparency / motion / colour accommodations honoured.
- Every string in a catalog; two complete translations; locale-aware numbers and dates.

Non-goals

- iOS, the plugin, more languages, RTL layout of the timeline.

## 2. Decisions

| Question | Decision |
|---|---|
| SwiftUI controls | `accessibilityLabel`, `accessibilityHint`, `accessibilityValue` and `accessibilityAddTraits` on every control in `TopBar`, `Toolbar*`, `Sidebar`, `MasterPanel`, `StatusBar`, `TabStrip`, `Welcome`, `Settings`, the cards and the export dialogs; icon-only buttons get the tooltip's text as the label. A single `AccessibilityText` namespace in `UI/Accessibility/` holds the strings so they are localized once. |
| Piano roll | `PianoRollView` overrides `accessibilityChildren()` returning cached `NSAccessibilityElement`s for the notes in the visible band (rebuilt when the band or the notes change, never per draw): role `.button`-like custom role "note", label "C4, Piano, bar 3 beat 2, half a beat", `isAccessibilitySelected`, custom actions Select, Delete, Open Note Card, Move Left/Right/Up/Down (through the existing `AppModel` nudges). `accessibilityFocusedUIElement` follows the selection's first note. |
| Keyboard, ruler, waveform | Each is an `NSAccessibilityElement`-conforming view with role `.slider`-like value: the keyboard reports the pitch under the pointer / last played; the ruler the playhead time and bar.beat, adjustable by ±1 beat through `accessibilityPerformIncrement/Decrement`; the waveform the input or playback level. |
| Score | `ScoreView` exposes systems as groups and each note as an element with its pitch, duration and part; reading order left to right, top to bottom; clicking through VoiceOver seeks as a click does. |
| Keyboard access | Every custom `NSView` that is interactive sets `acceptsFirstResponder` and draws the system focus ring (`focusRingType = .default`, `drawFocusRingMask`); the SwiftUI controls use `focusable()` where a custom control opted out; the cards are `NSPanel`s that become key and restore the previous key window on close (already done for the note card; checked for the others). |
| Accommodations | `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast / ReduceTransparency / ReduceMotion / DifferentiateWithoutColor` read into `Theme` at launch and on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`. Contrast: borders at full alpha, text at full contrast colours (`Theme.contrast` variants). Transparency: the floating cards and the welcome window use opaque backgrounds. Motion: the playhead follow uses an instant scroll; the welcome window's fades are 0 s. Colour: muted notes hatched; scale lanes get a dot in the gutter beside the key name. |
| Text size | SwiftUI text uses semantic fonts through `Fonts` (already a namespace) so `dynamicTypeSize` applies; the AppKit views keep `editorScale`. |
| Catalog | `Localizable.xcstrings` at `app/NeuralSheet/`; the build setting `SWIFT_EMIT_LOC_STRINGS = YES` so SwiftUI literals are extracted; AppKit and model strings through `String(localized:defaultValue:comment:)` with a comment naming the screen. Format strings use `String(localized:)` interpolation; plurals via `^[\(n) note](inflect: true)` where the catalog supports it, else explicit plural variants. |
| Numbers / dates | `Measurement`/`FormatStyle` for percentages, BPM, dB, times; `Date.FormatStyle` for version names; `TimeFormat` (Core) is locale-independent on purpose for the transport clock (`m:ss` is universal) — unchanged. |
| Translations | German and Spanish entries in the catalog, written by the implementing agent, then reviewed by a second agent (a separate `Agent` run) against the English and the comments; glossary fixed first (take = Aufnahme / toma, transcription = Transkription / transcripción, stems = Stems in both, grid = Raster / cuadrícula, key = Tonart / tonalidad …) and kept in `docs/design/localization-glossary.md`. |
| Guard | A script `app/Scripts/check-localizations.sh` runs `xcodebuild -exportLocalizations` for `de` and `es` and fails on any `<target>`-less `<trans-unit>`; the CI workflow runs it (one line in `.github/workflows`). |
| RTL | `.environment(\.layoutDirection, .leftToRight)` on the timeline and score hosts; menus and settings follow the system. |

## 3. Order of work

1. SwiftUI labels and traits; the `AccessibilityText` namespace. Audit the three windows.
2. The AppKit views' elements (roll, keyboard, ruler, waveform, score). Audit again.
3. Keyboard access and focus rings. Accommodations in `Theme`.
4. The catalog: extraction, `String(localized:)` sweep, formatters.
5. Glossary, German, Spanish; the review pass; the check script and CI line.
6. Changelog and the departures clause.

## 4. Changelog

"NeuralSheet speaks German and Spanish, and works with VoiceOver, full keyboard access and the
system's contrast, transparency and motion settings."
