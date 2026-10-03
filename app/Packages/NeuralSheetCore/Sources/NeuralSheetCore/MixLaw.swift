import Foundation

/// The crossfade between the take and the synth, the master fader and the stereo split, as one
/// pure function (audio export design §2): the live engine applies it to its graph, and the
/// offline renderer applies the same numbers to its own, so a file rendered "as heard" is what
/// playback sounds like rather than a second formula that drifts from it.
public enum MixLaw {
    /// What the three gain stages of the graph are set to.
    public struct Gains: Equatable, Sendable {
        /// The take's gain, the master folded in: the source node applies it itself, ramped
        /// inside the block, and joins the graph after the master fader.
        public var source: Float
        /// The synth sub-mix's output volume: the synth's side of the crossfade, before the
        /// master.
        public var synth: Float
        /// The master fader as a linear gain, the synth path's master mixer volume.
        public var master: Float
        /// The take panned hard left and the synth hard right.
        public var stereoSplit: Bool

        public init(source: Float, synth: Float, master: Float, stereoSplit: Bool) {
            self.source = source
            self.synth = synth
            self.master = master
            self.stereoSplit = stereoSplit
        }
    }

    /// The equal-power crossfade at `mix` (0 = the take alone, 1 = the synth alone): `cos` and
    /// `sin` of `mix · π/2`, so the two sum to constant power and each is −3 dB at the middle.
    public static func gains(mix: Double) -> (original: Float, synth: Float) {
        let position = mix.isFinite ? min(max(mix, 0), 1) : 0
        let angle = position * Double.pi / 2

        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// The master fader in linear terms: −36 dB is the fader's silent end, not a very quiet one,
    /// and MUTE silences it outright.
    public static func masterGain(db: Double, muted: Bool) -> Double {
        let clamped = min(max(db, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)

        return muted || clamped <= InstrumentMixerState.minGainDb ? 0 : pow(10.0, clamped / 20.0)
    }

    /// Every gain the graph needs, from the controls.
    ///
    /// With no notes there is nothing on the synth side to fade to, so the mix is forced to
    /// all-source (inventory §5.3). Under the split each side plays at full in its own ear, and a
    /// hold (`mix` at exactly 0 or 1) silences the other ear; with no notes the source stays on.
    public static func resolve(mix: Double, masterGainDb: Double, muted: Bool, stereoSplit: Bool,
                               hasNotes: Bool) -> Gains {
        let master = masterGain(db: masterGainDb, muted: muted)

        if stereoSplit {
            let sourceOn = !hasNotes || mix < 1
            let synthOn = hasNotes && mix > 0

            return Gains(source: Float(sourceOn ? master : 0), synth: synthOn ? 1 : 0, master: Float(master),
                         stereoSplit: true)
        }

        let crossfade = gains(mix: hasNotes ? mix : 0)

        return Gains(source: Float(Double(crossfade.original) * master), synth: crossfade.synth,
                     master: Float(master), stereoSplit: false)
    }
}
