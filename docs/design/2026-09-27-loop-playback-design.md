# Loop playback — Design

The Loop button has sat disabled in the top bar since the parity build, because NeuralNote never
implemented it. Every tool people learn a part with — Transcribe!, Moises, AnthemScore, any DAW —
repeats a stretch of the take until it is learnt. This gives the button its job: with a range
marked on the ruler, playback repeats that range; without one, it repeats the whole take.

It builds on the region re-transcription design (`2026-09-21-instrument-commands-and-region-
retranscription-design.md`), whose ruler range it reuses. Everything it does not mention is
unchanged. Where it departs from the NeuralNote inventory (`2026-09-17-neuralnote-feature-
inventory.md`) it says so in §7.

## 1. Goals and non-goals

Goals

- Loop on: the playhead runs to the end of the loop and continues from its start, without a
  gap, with the audio sample-accurate across the jump and the synth releasing what was sounding
  and re-attacking what covers the start.
- The loop is the marked range when there is one, the whole take otherwise.
- A range can be marked as soon as there is audio, so a passage can be practised against the
  original before it is transcribed.
- Nothing in the render block allocates, locks or dispatches. The jump is the render thread's
  alone.
- The frame arithmetic lives in `NeuralSheetCore` behind `swift test`.

Non-goals

- Loop handles, a separate loop region, or several loops. The range is the loop.
- A count-in, a pre-roll, or a repeat count.
- Saving the loop or the range in the project. Both are transient, as the range already is.
- A note-off for one-shot drum hits at the jump. A hit is 10 ms; its tail is not worth a
  render-thread path into CC 123.

## 2. Decisions

| Question | Decision |
|---|---|
| What is looped? | `editor.range` when set; else `0 ..< duration`. Both ends land where the range drag put them (snapped when snap is on). |
| Where does Play start with the loop on? | Where the playhead is. A playhead before the loop plays into it and then repeats; one at or past its end jumps to the start at the next block. |
| Return / Shift + Space? | Still 0. The loop is a repeat, not a new origin. |
| End of the take? | Never reached while looping: the loop end is at most the take's end, and the jump comes first. |
| What does the button show? | On: the accent fill and accent icon `FlatButton` already has for a lit transport button. Enabled whenever `canPlay`. |
| Key? | `l`, both tabs. |
| The range before a transcription? | Allowed in every `canPlay` state. `transition(to:)` clears it when the new state cannot play, rather than when it is not `.populated`. Re-transcribe still needs `.populated`. |
| Saved? | No. `loopEnabled` is not in `ProjectContent`; a project opens with the loop off. |

## 3. Frame arithmetic (`NeuralSheetCore/LoopWindow.swift`)

```swift
public struct LoopWindow: Equatable, Sendable {
    public var start: Int          // frames, inclusive
    public var end: Int            // frames, exclusive; end > start
    public var length: Int { end - start }

    public init?(start: Int, end: Int)                   // nil unless 0 <= start < end
    public init?(seconds: Range<Double>, sampleRate: Double, frameCount: Int)
                                                          // rounded, clamped to 0 ... frameCount

    public func wrapped(_ position: Int) -> Int          // position < end ? position : start + (position - end) % length
    public func advance(from playhead: Int, frames: Int) -> (renderEnd: Int, next: Int)

    public var packed: UInt64                             // start << 32 | end, for one atomic
    public init?(packed: UInt64)                          // nil for 0
}
```

`advance` is what the render block asks after a block of `frames` starting at `playhead`:
`renderEnd` is where the synth is scheduled up to (`min(playhead + frames, end)` when the block
started inside the loop, `playhead + frames` when it started past the end), and `next` is the
playhead for the following block (`wrapped(playhead + frames)`, or `start` when the block started
at or past the end).

The pair packs into one 64-bit word so the render block reads both ends in one atomic load and
never sees one end from a newer loop than the other. Frame counts fit 32 bits up to a day of
audio at 48 kHz.

Tests: `wrapped` on either side of the end and over a loop shorter than the overshoot; `advance`
inside, crossing, at and past the end; the seconds initialiser rounds and clamps and refuses a
range outside the take or under a frame; `packed` round-trips and 0 is nil.

## 4. Render thread (`Audio/PlaybackEngine.swift`, `Audio/NoteScheduler.swift`)

`RenderState` gains

- `loopBits: Atomic<UInt64>`, 0 for no loop, written from the main thread;
- `lastBlockStart: Int` and `continuous: Bool`, render thread only.

The block today reads the take one buffer behind the playhead (`readStart = playhead - frames`)
so the audio lines up with MIDI scheduled a cycle ahead. Through a jump that delay has to follow
the loop too: the block after the jump reads from where the block before it stopped, not from
`start - frames`. So the read position becomes the previous block's playhead, kept in
`lastBlockStart`, and falls back to `playhead - frames` after a seek or a block that did not
render (`continuous == false`). With constant block sizes and no loop this is exactly what it
was.

Each sample's index is `wrapped` into the loop when one is set, so a block whose read window
crosses the end takes its remaining samples from the start. A loop shorter than a block is
handled by the modulo in `wrapped`.

After rendering, `advance` decides the next playhead. With a loop set the end-of-take check is
skipped: the jump is the end. The synth is scheduled from the block's start to `renderEnd`, so
no note past the loop end is attacked in the block that crosses it.

`NoteScheduler.collect` today rebuilds its cursor on a discontinuity (`t0 != lastEndTime`) but
releases and re-attacks only on the main thread's `shouldResync` flag. A loop jump is a
discontinuity the transport made itself, so a discontinuity on a playing block now also
releases everything sounding and re-attacks what covers `t0`, through the same code the flag
uses. The first block (`lastEndTime < 0`) is not a discontinuity. A main-thread seek raises the
flag and jumps; the two paths are the same path, so nothing is released or attacked twice.

Engine API, main thread:

```swift
var loop: Range<Double>? { didSet { applyLoop() } }   // seconds; nil for off
```

`applyLoop` converts to a `LoopWindow` at the engine's rate against the current take
(`frameCount`) and stores `packed`, or 0 with no take or a window that does not fit.
`setSource` and `rebuildGraph` call it again, since the frame count and the rate can change.

## 5. Model (`App/AppModel.swift`, new `App/AppModel+Loop.swift`)

- `private(set) var loopEnabled = false` on `AppModel` (transient; the stored property has to
  sit in the class body).
- `toggleLoop()`: flips it when `state.canPlay`.
- `applyLoop()`: `engine.loop = loopEnabled ? (editor.range ?? 0 ..< duration) : nil`. Called
  from `toggleLoop`, from `editor`'s `didSet` when the range changed, from `duration`'s `didSet`,
  and after `installSource`. A `duration` of 0 gives the engine nil.
- The range: `setRange` refuses unless `state.canPlay`; `transition(to:)` clears it when
  `!newState.canPlay`. `resetTranscription` keeps clearing it, as every clear and load does.
- `KeyboardShortcuts`: `l` → `toggleLoop()`, both tabs, not on repeat.

## 6. UI (`UI/TopBar/TopBar.swift`)

The Loop button: `isOn: model.loopEnabled`, `isEnabled: canPlay`, `action: model.toggleLoop`,
tooltip `"Loop | l"`. The range band is unchanged: with the loop on and a range marked, the band
is the loop; with the loop on and no range, the lit button is the only sign, as it is in a DAW
whose cycle is the whole song.

## 7. Departures from the inventory

- §1.3 / §5.1 / §11.4: the Loop button is enabled and loops; its tooltip is `"Loop | l"` rather
  than `"Loop (not implemented yet)"`. The inventory recorded NeuralNote's disabled button.
- Region design §4.2: the range is allowed in every `canPlay` state, not only `.populated`.

## 8. Tests and verification

- `LoopWindowTests` as in §3.
- Build warning-free; `swift test` green.
- By ear: mark a range in the Transcribe tab on an untranscribed take, Loop, Play — the audio
  repeats without a click at the seam; with a transcription, a note held across the loop end is
  released at the jump and a note covering the loop start sounds from the jump; Loop with no
  range repeats the whole take instead of stopping; a seek while looping lands where clicked and
  keeps looping; turning Loop off mid-loop plays on to the end and stops as before.

## 9. Order of work

1. **core**: `LoopWindow` + tests.
2. **audio**: `RenderState` fields, the render block's read position and jump, the scheduler's
   discontinuity resync, `PlaybackEngine.loop`.
3. **app**: `loopEnabled`, `toggleLoop`, `applyLoop`, the range in every `canPlay` state, the key.
4. **ui**: the button.
5. **docs**: AGENTS.md departures, the changelog, the region design's §4.2 note, the top bar's
   inventory citation.
