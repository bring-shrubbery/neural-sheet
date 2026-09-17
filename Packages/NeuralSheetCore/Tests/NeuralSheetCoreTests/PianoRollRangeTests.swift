import Testing

@testable import NeuralSheetCore

@Test func anEmptyRollShowsCZeroThroughBFive() {
    #expect(PitchRange.empty == PitchRange(low: 12, high: 83))
    #expect(PitchRange.empty.count == 72)

    let range = PianoRollRange.displayRange(notes: nil, highest: nil, minSemitones: 12)

    #expect(range == PitchRange(low: 12, high: 83))
}

@Test func theRangeIsWholeOctavesAroundTheNotes() {
    // C4..G4 sits inside one octave, which is already the minimum.
    #expect(
        PianoRollRange.displayRange(notes: 60, highest: 67, minSemitones: 12)
            == PitchRange(low: 60, high: 71))

    // C2..G5 spans four octaves; nothing is widened because the minimum is met.
    #expect(
        PianoRollRange.displayRange(notes: 36, highest: 79, minSemitones: 12)
            == PitchRange(low: 36, high: 83))
}

@Test func aNarrowRangeWidensAboveFirstThenAlternates() {
    // One octave, asked for two: the octave above is added, so the notes sit low in the view.
    #expect(
        PianoRollRange.displayRange(notes: 60, highest: 67, minSemitones: 24)
            == PitchRange(low: 60, high: 83))

    // Three: above, then below.
    #expect(
        PianoRollRange.displayRange(notes: 60, highest: 67, minSemitones: 36)
            == PitchRange(low: 48, high: 83))

    // Four: above, below, above.
    #expect(
        PianoRollRange.displayRange(notes: 60, highest: 67, minSemitones: 48)
            == PitchRange(low: 48, high: 95))
}

@Test func wideningStopsAtTheMidiRange() {
    let range = PianoRollRange.displayRange(notes: 60, highest: 67, minSemitones: 1000)

    #expect(range == PitchRange(low: 0, high: 127))
    #expect(range.count == 128)
}

@Test func theTopOctaveIsClampedToTheLastMidiNote() {
    // Octave 10 is 120..131; only 120..127 exist.
    #expect(
        PianoRollRange.displayRange(notes: 121, highest: 125, minSemitones: 1)
            == PitchRange(low: 120, high: 127))
}

@Test func outOfOrderAndOutOfRangeNotesAreTakenAsGiven() {
    // Lowest and highest swapped by the caller.
    #expect(
        PianoRollRange.displayRange(notes: 79, highest: 36, minSemitones: 12)
            == PitchRange(low: 36, high: 83))

    // Pitches outside 0..127 are clamped before the octaves are taken.
    #expect(
        PianoRollRange.displayRange(notes: -5, highest: 200, minSemitones: 12)
            == PitchRange(low: 0, high: 127))
}

@Test func oneMissingEndpointStillCountsAsNotes() {
    #expect(
        PianoRollRange.displayRange(notes: 60, highest: nil, minSemitones: 12)
            == PitchRange(low: 60, high: 71))
    #expect(
        PianoRollRange.displayRange(notes: nil, highest: 67, minSemitones: 12)
            == PitchRange(low: 60, high: 71))
}

@Test func unionOnlyEverWidens() {
    let a = PitchRange(low: 48, high: 83)
    let b = PitchRange(low: 60, high: 95)

    #expect(PianoRollRange.union(a, b) == PitchRange(low: 48, high: 95))
    #expect(PianoRollRange.union(b, a) == PitchRange(low: 48, high: 95))
    #expect(PianoRollRange.union(a, a) == a)
    #expect(PianoRollRange.union(a, PitchRange(low: 60, high: 71)) == a)
}
