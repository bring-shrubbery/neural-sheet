import Testing

@testable import NeuralSheetCore

private func note(_ start: Double, _ end: Double, confidence: Double? = 0.9) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: 60, program: 0, confidence: confidence)
}

@Test func zeroThresholdsChangeNothing() {
    let notes = [note(0, 0.001, confidence: 0.01), note(1, 2, confidence: nil)]

    #expect(NoteFilter.apply(notes, minimumLength: 0, minimumConfidence: 0) == notes)
}

@Test func aNoteOfExactlyTheMinimumLengthIsKept() {
    // 1.00 to 1.05 is 0.04999… in binary; it is still a 50 ms note.
    let notes = [note(1.0, 1.05), note(2.0, 2.049), note(3.0, 3.051)]
    let kept = NoteFilter.apply(notes, minimumLength: 0.05, minimumConfidence: 0)

    #expect(kept == [notes[0], notes[2]])
}

@Test func aNoteAtTheConfidenceThresholdIsKept() {
    let notes = [note(0, 1, confidence: 0.5), note(1, 2, confidence: 0.49), note(2, 3, confidence: 0.51)]
    let kept = NoteFilter.apply(notes, minimumLength: 0, minimumConfidence: 0.5)

    #expect(kept == [notes[0], notes[2]])
}

@Test func aNoteWithoutConfidenceIsNeverDroppedForIt() {
    let notes = [note(0, 1, confidence: nil)]

    #expect(NoteFilter.apply(notes, minimumLength: 0, minimumConfidence: 0.75) == notes)
}

@Test func bothThresholdsApplyTogetherAndKeepOrder() {
    let notes = [note(0, 1, confidence: 0.9), note(1, 1.01, confidence: 0.9), note(2, 3, confidence: 0.2), note(3, 4)]
    let kept = NoteFilter.apply(notes, minimumLength: 0.02, minimumConfidence: 0.25)

    #expect(kept == [notes[0], notes[3]])
}

@Test func doubtfulIsUnderHalfOrShortWhenTheLengthSettingIsOn() {
    #expect(NoteFilter.isDoubtful(note(0, 1, confidence: 0.49), minimumLength: 0))
    #expect(!NoteFilter.isDoubtful(note(0, 1, confidence: 0.5), minimumLength: 0))
    #expect(!NoteFilter.isDoubtful(note(0, 1, confidence: nil), minimumLength: 0))
    #expect(!NoteFilter.isDoubtful(note(0, 0.01), minimumLength: 0))
    #expect(NoteFilter.isDoubtful(note(0, 0.01), minimumLength: 0.02))
    #expect(NoteFilter.isDoubtful(note(0, 0.01, confidence: nil), minimumLength: 0.02))
}
