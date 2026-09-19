/// A range of MIDI notes to show, inclusive at both ends.
public struct PitchRange: Equatable, Sendable {
    public var low: Int
    public var high: Int

    /// How many semitones the range spans.
    public var count: Int { high - low + 1 }

    public init(low: Int, high: Int) {
        self.low = low
        self.high = high
    }

    /// Octaves 1-5, MIDI 12-71: the span an empty piano roll starts from before it is widened
    /// to fill.
    public static let empty = PitchRange(low: 12, high: 71)
}

/// Which notes the piano roll shows.
public enum PianoRollRange {
    public static let minMidiNote = 0
    public static let maxMidiNote = 127

    /// Octaves 1-5, MIDI 12-71: the span an empty piano roll starts from before it is widened
    /// to fill. Octaves here are 0-based indices into the MIDI range (`note / 12`), not the octave
    /// in a note's name.
    public static let defaultLowOctave = 1
    public static let defaultHighOctave = 5

    /// The octave a MIDI note falls in, 0 for notes 0-11. Not the octave in its name.
    public static func octave(of note: Int) -> Int { note / 12 }

    /// The highest octave with any note in it. Its top note, 131, does not exist.
    public static let lastOctave = maxMidiNote / 12

    private static func range(lowOctave: Int, highOctave: Int) -> PitchRange {
        PitchRange(low: lowOctave * 12, high: min(highOctave * 12 + 11, maxMidiNote))
    }

    /// Which notes the piano roll should show.
    ///
    /// Two rules, in this order. The range covers every transcribed note, so limiting it never
    /// hides one — it only drops the octaves nothing reached. And it is never narrower than
    /// `minSemitones`, so the keyboard fills its column rather than leaving a gap: that is what
    /// decides how far past the notes it opens up, and why an empty roll can end up a little wider
    /// than octaves 1-5.
    ///
    /// Whole octaves throughout, so the C separators the roll draws land on its edges.
    ///
    /// - Parameters:
    ///   - lowest: Lowest transcribed note, or `nil` when there is no transcription to fit around.
    ///   - highest: Highest transcribed note, or `nil`. One endpoint alone still counts as notes.
    ///   - minSemitones: The narrowest range the view can show without leaving a gap.
    public static func displayRange(notes lowest: Int?, highest: Int?, minSemitones: Int)
        -> PitchRange
    {
        var lowOctave = defaultLowOctave
        var highOctave = defaultHighOctave

        if lowest != nil || highest != nil {
            let a = lowest ?? highest!
            let b = highest ?? lowest!
            let clamp = { (note: Int) in min(max(note, minMidiNote), maxMidiNote) }

            lowOctave = octave(of: clamp(min(a, b)))
            highOctave = octave(of: clamp(max(a, b)))
        }

        // Widen an octave at a time, above first so the notes sit low in the view rather than high,
        // until the range is at least as long as the space it has. Bounded by the MIDI range on
        // both sides, so a roll taller than 128 keys simply shows all of them.
        var growUpwards = true

        while range(lowOctave: lowOctave, highOctave: highOctave).count < minSemitones
            && (lowOctave > 0 || highOctave < lastOctave)
        {
            if growUpwards && highOctave < lastOctave {
                highOctave += 1
            } else if lowOctave > 0 {
                lowOctave -= 1
            } else {
                highOctave += 1
            }

            growUpwards.toggle()
        }

        return range(lowOctave: lowOctave, highOctave: highOctave)
    }

    /// The range to show while a transcription is streaming in: the one the notes so far ask for,
    /// but never narrower than what is already on screen. Without this the view would jump every
    /// time a chunk introduced a note outside the previous span.
    public static func union(_ a: PitchRange, _ b: PitchRange) -> PitchRange {
        PitchRange(low: min(a.low, b.low), high: max(a.high, b.high))
    }
}
