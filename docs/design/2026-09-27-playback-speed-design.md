# Playback speed — Design

Learning a passage means hearing it slower than it was played, at the pitch it was played. Every
practice tool has the control (Transcribe!, Moises, AnthemScore, the DAWs' varispeed with pitch
held); NeuralSheet plays the take at one speed. This adds a SPEED pill to the top bar: the take
plays at 50…150 % of its tempo with its pitch unchanged, and the MIDI follows the same clock, so
the synth stays on the notes while both slow down together.

It builds on the loop design (`2026-09-27-loop-playback-design.md`). Everything it does not
mention is unchanged.

## 1. Goals and non-goals

Goals

- A speed of 0.5…1.5 applied to the take and to the MIDI clock alike, changed while playing,
  with no gap, and at exactly 1.0 the sample-exact path the app has today.
- The time stretch runs on the render thread without allocating or locking, with all of its
  memory allocated when the engine is built.
- The stretch and its tracking live in `NeuralSheetCore` behind `swift test`.
- The loop and the speed compose: a looped range at half speed repeats seamlessly.

Non-goals

- A pitch shift of the take. The stretch is pitch-preserving; transposing is a later change.
- Saving the speed in the project. It is a practice setting, transient like the loop.
- Spectral (phase-vocoder) quality. A time-domain WSOLA stretch is what the practice tools of
  the last twenty years shipped; it keeps transients and costs a few hundred multiplies per
  output frame.

## 2. Decisions

| Question | Decision |
|---|---|
| Algorithm | WSOLA (waveform-similarity overlap-add): 100 ms windows overlapped by 12 ms, each new window placed by the best correlation within ±12.5 ms of where the speed says it belongs. |
| Where it runs | Inside the source node's render block, fed from the take's buffer through the same wrapped index the loop uses. Not an `AVAudioUnitTimePitch` in the graph: the unit pulls its input on its own cadence and in its own time base, and the MIDI is scheduled off this block's timestamp; keeping both in one block keeps them on one clock. |
| The MIDI clock | The playhead advances `frames × speed` take-frames per block. The scheduler is given `sampleRate / speed` as its rate, which puts a note `Δ` seconds into the block at output frame `Δ × rate / speed` and stretches note lengths with the audio. |
| At exactly 1.0 | The direct read the block has today, untouched. The stretcher is reset the moment the speed leaves 1.0 and dropped when it returns. |
| Range and step | 0.5…1.5, step 0.05, default 1.0; the slider's centre is 100 %. |
| Keys | `-` slower, `=` faster, a step each; double-click on the slider resets to 100 %. |
| Where | The top bar, after the time display, in the pill style the volume had there: SPEED, the slider, the percentage. Dimmed unless `canPlay`. |

## 3. The stretcher (`NeuralSheetCore/TimeStretcher.swift`)

```swift
public final class TimeStretcher {
    public struct Input {                       // the take, as the render thread sees it
        public var left: UnsafePointer<Float>
        public var right: UnsafePointer<Float>  // == left for a mono take
        public var frameCount: Int
        public var isStereo: Bool
        public var loop: LoopWindow?
        public func sample(_ channel: Int, at index: Int) -> Float   // 0 outside the take; wrapped into the loop
    }

    public init(sampleRate: Double, maxBlockFrames: Int = 8192)
    public var speed: Double                    // clamped 0.25…4
    public private(set) var position: Double    // take frame the next window is placed at
    public func reset(at position: Double, input: Input)
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                       frames: Int, input: Input)
}
```

State: a planar output ring of `maxBlockFrames + windowLength` frames per channel, the un-emitted
tail (`overlap` frames per channel), a mono scratch for the search, and `position`, the take
frame the next window's crossfade region nominally starts at.

One iteration produces `window − overlap` output frames:

1. Take the mono of `input[position − seek/2 … position + seek/2 + overlap)` into the scratch
   (wrapped into the loop, 0 outside the take) and the mono of the tail.
2. For each offset in the seek span, the dot product of the tail against the scratch at that
   offset, divided by the square root of the scratch segment's energy (kept as a sliding sum);
   the best offset is `pos`.
3. Emit `overlap` frames of a linear crossfade from the tail into `input[pos …)`, then
   `window − 2·overlap` frames copied from `input[pos + overlap …)`; keep `input[pos + window −
   overlap … pos + window)` as the new tail.
4. `position += (window − overlap) × speed`, wrapped into the loop.

`render` drains the ring into the output, running iterations whenever the ring holds fewer than
`frames`; a block larger than the ring can serve is silence. `reset(at:)` clears the ring, sets
`position`, and seeds the tail from `input[position … position + overlap)`, so at speed 1.0 the
first iteration's best offset is `position` itself and the output is the input sample for sample.

Tests: identity at speed 1.0 on noise; the position advances `frames × speed` per rendered
frame; a 440 Hz sine at 0.5 and at 1.5 comes out with its zero-crossing rate within 2 % of
440 Hz; a looped input wraps through `Input.sample` and through `position`; nothing exceeds the
input's peak.

`LoopWindow` gains `wrapped(_: Double)` and `advance(from: Double, span: Double)` for the
fractional playhead.

## 4. Render thread (`Audio/PlaybackEngine.swift`)

`RenderState` gains `speedBits: Atomic<UInt32>` (a `Float`'s bits, 1.0 by default), a
render-thread `playheadExact: Double` beside the published `playheadFrames` (which becomes its
rounding), `stretcher: TimeStretcher` (replaced with the meter when the rate changes, engine
stopped) and `stretching: Bool`.

The block, with `speed` read once and `span = frames × speed`:

- speed 1.0: the direct read as today, from `lastBlockStart` when the previous block was direct
  and continuous, else from `playhead − frames`; `stretching = false`.
- otherwise: if not `stretching`, or after a seek or a non-rendered block, `reset(at: playhead −
  span)`, the same one-block-behind the direct read keeps; then `render` into the outputs and
  the gain ramp over them in place; `continuous = false`, so a return to the direct read falls
  back to `playhead − frames`.
- advance: `loop.advance(from: playhead, span:)` or `playhead += span`, the end-of-take rule on
  the exact position; `playheadFrames` stores the rounding.
- `bank.schedule(from:to:…, sampleRate: rate / speed)`.

Engine API: `var speed: Double = 1 { didSet }` storing the clamped bits.

## 5. Model (`App/AppModel.swift`, `App/AppModel+Loop.swift` → renamed `AppModel+Practice.swift`)

- `var playbackSpeed: Double = 1 { didSet { engine.speed = playbackSpeed } }`, clamped to
  `AppModel.speedRange` by `setPlaybackSpeed(_:)`.
- `nudgeSpeed(steps:)`: a step of 0.05 per press, landing on multiples, for `-` and `=`.
- `resetSpeed()` for the double-click.
- `KeyboardShortcuts`: `-` → slower, `=` → faster, both tabs, repeating.

## 6. UI (`UI/TopBar/SpeedPill.swift`, `UI/TopBar/TopBar.swift`)

After the time display and a group gap: a pill in the volume pill's metrics (30 tall, 12 padding,
9 gap, corner 6, `bgControl`): the label SPEED in the pill-label font and `textMuted`, a
`PillSlider` 74 wide (range 0.5…1.5, step 0.05, `volumeFill` fill, `faderTrackTop`, `faderThumb`,
double-click resets), and a right-aligned percentage in `Fonts.meta` and `textMuted`, 34 wide.
Dimmed to the disabled alpha unless `canPlay`. Tooltip on the slider: `"Playback speed, pitch
unchanged | - ="`.

## 7. Departures from the inventory

- §1.3: the top bar gains a SPEED pill after the time display. NeuralNote played at one speed.

## 8. Tests and verification

- `TimeStretcherTests` as in §3; `LoopWindowTests` for the fractional overloads.
- Build warning-free; `swift test` green.
- By ear: a take at 50 % keeps its pitch and its MIDI on the beat; the speed slides while
  playing without a gap; returning to 100 % gives the original sound; a loop at 75 % repeats
  seamlessly; a seek at any speed lands where clicked.

## 9. Order of work

1. **core**: `LoopWindow` fractional overloads, `TimeStretcher`, tests.
2. **audio**: the render block's speed path, `PlaybackEngine.speed`.
3. **app**: `playbackSpeed`, the nudge and reset, the keys.
4. **ui**: `SpeedPill` in the top bar.
5. **docs**: AGENTS.md departures, the changelog.
