# Tempo detection and tap tempo — Design

The Edit tab's grid is one BPM and one downbeat, both typed in. Typing a tempo is guesswork,
and until it is right the bars-and-beats ruler, snapping and quantize are all wrong. Every
practice and notation tool offers at least one of two remedies: tap the tempo along with the
music, or let the program find it in the audio. This adds both to the Edit toolbar's tempo
group: **Tap**, which sets the BPM from the intervals between presses while the take plays, and
**Detect**, which finds the tempo and a downbeat in the take's audio.

It builds on the editor design (`2026-09-19-midi-editor-design.md`, §4.5 and §6.1). Everything
it does not mention is unchanged.

## 1. Goals and non-goals

Goals

- Tap: after two presses in time with playback the BPM follows the taps, steadier with each
  one; the intervals are measured on the take's clock, so tapping works at any playback speed.
- Detect: one press sets the BPM to the take's tempo, to the integer, and BEAT 1 AT to a
  downbeat, from the audio alone, so it works on an untranscribed take too. A take with no beat
  to find says so.
- The estimator and the tap logic live in `NeuralSheetCore` behind `swift test`, with
  synthetic click tracks as the fixtures.
- Detection runs off the main thread; the window stays live.

Non-goals

- Tempo changes or a tempo map. The grid stays one BPM.
- Time signatures other than 4/4. The downbeat is chosen among the four beat phases of a bar.
- Beat-by-beat tracking, or drawing detected beats on the ruler. The grid is the result.
- Undo for the grid. The tempo and the offset were never in the undo stack; they are in the
  project's dirty rule, as before.

## 2. Decisions

| Question | Decision |
|---|---|
| What sets the BPM from taps? | The median of the intervals between the last eight taps, converted to BPM and rounded to the integer, once there are two taps. |
| What ends a tap series? | An interval outside 0.25…2 s (240…30 BPM): the press starts a new series. A stopped transport takes no taps. |
| Do taps move the downbeat? | No. Taps set the tempo; BEAT 1 AT stays. The ⌖ button beside it and Detect are how the downbeat moves. |
| Detection method | An onset-strength envelope (spectral flux of a 512-point STFT at 200 Hz on the 16 kHz mono), detrended; its autocorrelation over 40…240 BPM weighted by a log-Gaussian prior about 120 BPM; the peak refined by parabolic interpolation and rounded to the integer; then the beat phase from a comb at that period, and the downbeat as the strongest of the four beat phases of a bar. |
| What does Detect write? | `bpm` and `offsetSeconds` together, the offset being the earliest downbeat at or after 0. The grid division is untouched. |
| Failure | Under four seconds of audio, or an envelope with nothing in it: `"Could not detect a tempo."` / `"The take is too short or has no clear beat."` in the standard dialog. |
| Keys | `t` taps, both tabs (the tap has to happen while listening, which may be in the Transcribe tab). No key for Detect. |
| Where | Two label buttons after the ⌖ button in the Edit toolbar's tempo group: `Tap`, `Detect`. Detect is disabled at 0.38 while a detection runs. |

## 3. Core (`NeuralSheetCore`)

### 3.1 `TapTempo.swift`

```swift
public struct TapTempo: Equatable, Sendable {
    public static let minInterval = 0.25, maxInterval = 2.0, window = 8
    public init()
    public mutating func tap(at seconds: Double) -> Double?   // the BPM, or nil until two taps
    public mutating func reset()
}
```

`tap` appends the time; an interval from the previous tap outside the bounds drops everything
before this tap. With two or more taps it returns `60 / median(intervals of the last eight)`,
rounded to the integer and clamped to `TempoGrid`'s range.

Tests: four taps 0.5 s apart give 120; intervals 0.5, 0.52, 0.48, 0.5 give 120 (the median);
a 3 s gap starts over and the tap after it is nil; a 0.1 s double-press starts over; a series
at half speed on the take's clock still reads the take's tempo.

### 3.2 `TempoEstimator.swift`

```swift
public struct TempoEstimate: Equatable, Sendable {
    public var bpm: Double              // integer-valued
    public var downbeatSeconds: Double  // earliest downbeat ≥ 0
}

public enum TempoEstimator {
    public static let sampleRate = 16_000.0, hop = 80, window = 512   // 200 Hz envelope
    public static let minBpm = 40.0, maxBpm = 240.0
    public static func estimate(mono16k: [Float]) -> TempoEstimate?
    // The stages, internal, for the tests:
    static func onsetEnvelope(_ samples: [Float]) -> [Float]
    static func tempo(from envelope: [Float]) -> Double?
    static func downbeat(in envelope: [Float], bpm: Double) -> Double
}
```

Envelope: Hann-windowed frames every 80 samples, magnitude spectrum through `vDSP_fft_zrip`,
`log(1 + 1000·|X|)`, the half-wave-rectified difference to the previous frame summed over the
bins; then less a ±0.5 s moving mean, rectified; then a three-frame moving mean.

Tempo: `ac[l] = Σ e[n]·e[n+l] / (N − l)` for lags 50…300 frames, times
`exp(−½ (log₂(l / 100) / 1.0)²)`; the best lag refined by a parabola through its neighbours;
`bpm = 12 000 / lag` folded into 60…200 by octaves, rounded to the integer. Nil under four
seconds of envelope or when the envelope is all zero.

Downbeat: with `τ = 12 000 / bpm` frames, fold the envelope into `⌈τ⌉` bins by
`n mod τ`; the fullest bin is the beat phase `φ`. Then among `φ + mτ` for `m` in 0…3, the phase
whose comb at period `4τ` collects the most energy; that phase in seconds, `/ 200`.

Tests, on synthetic click tracks at 16 kHz (10 ms bursts of a 2 kHz tone, decaying), 20 s long:
120 BPM with beat 1 at 0.3 s and every fourth click at twice the level gives `bpm == 120` and
a downbeat within 15 ms of 0.3 (or of 0.3 plus whole bars); 90 BPM with beat 1 at 0.1 s gives
90; silence and two seconds of clicks give nil.

## 4. Model (`App/AppModel+Tempo.swift`, `App/AppModel.swift`)

- `@ObservationIgnored var tapTempo = TapTempo()` and `private(set) var isDetectingTempo =
  false` on `AppModel`.
- `tap()`: guard `state.canPlay`, `isPlaying`; `tapTempo.tap(at: playheadSeconds)` and, with a
  BPM, `setGridBpm`. A stopped transport is refused; the taps are on the take's clock, so the
  speed does not matter.
- `detectTempo()`: guard a take, `!isDetectingTempo`; set the flag; `Task.detached` runs
  `TempoEstimator.estimate(mono16k:)` on the take's model copy (immutable, so it is safe to read
  off the main actor); back on the main actor, and only if the take is still the same object,
  `setGridBpm` and `setGridOffset`, or the dialog; clear the flag.
- `KeyboardShortcuts`: `t` → `tap()`, both tabs, not on repeat. The Edit tab's key table gains
  it; `r` stays swallowed there.

## 5. UI (`UI/Toolbar/EditToolbar.swift`)

After the ⌖ button, inside the same `HStack(spacing: 6)`: `labelButton("Tap", tooltip: "Tap in
time with playback to set the tempo | t", action: model.tap)` and `labelButton("Detect",
tooltip: "Find the tempo and the downbeat in the audio", isEnabled: !model.isDetectingTempo,
action: model.detectTempo)`. `labelButton` gains an `isEnabled` parameter, defaulting to true.

## 6. Departures from the inventory

None: NeuralNote had no grid. The editor design's §6.1 item 3 gains the two buttons.

## 7. Tests and verification

- `TapTempoTests`, `TempoEstimatorTests` as in §3.
- Build warning-free; `swift test` green.
- By hand: tap `t` along with a take, the TEMPO field settles on the tempo; press Detect on a
  song with a clear beat, the ruler's bars line up with it; Detect on two seconds of room
  noise shows the dialog.

## 8. Order of work

1. **core**: `TapTempo`, `TempoEstimator`, tests.
2. **app**: the model's tap and detect, the key.
3. **ui**: the two buttons.
4. **docs**: the editor design's §6.1 note, the changelog.
