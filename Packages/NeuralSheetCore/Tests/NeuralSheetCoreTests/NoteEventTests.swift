import Testing

@testable import NeuralSheetCore

private func note(
    _ start: Double, _ end: Double, pitch: Int, program: Int = 0, amplitude: Double = 0.5
) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, amplitude: amplitude, program: program)
}

@Test func initAppliesDefaultAmplitude() {
    let event = NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)
    #expect(event.amplitude == NoteEvent.defaultAmplitude)
    #expect(NoteEvent.defaultAmplitude == 100.0 / 127.0)
}

@Test func isDrumOnlyForProgram128() {
    #expect(note(0, 1, pitch: 38, program: NoteEvent.drumProgram).isDrum)
    #expect(NoteEvent.drumProgram == 128)
    #expect(!note(0, 1, pitch: 38, program: 0).isDrum)
    #expect(!note(0, 1, pitch: 38, program: 127).isDrum)
}

@Test func sortOrderIsStartProgramPitchEnd() {
    let byStart = [note(0, 1, pitch: 60, program: 5), note(1, 2, pitch: 40, program: 0)]
    #expect(byStart.sorted() == byStart)

    let byProgram = [note(0, 1, pitch: 90, program: 0), note(0, 1, pitch: 40, program: 1)]
    #expect(byProgram.sorted() == byProgram)

    let byPitch = [note(0, 1, pitch: 40, program: 3), note(0, 1, pitch: 41, program: 3)]
    #expect(byPitch.sorted() == byPitch)

    let byEnd = [note(0, 1, pitch: 40, program: 3), note(0, 2, pitch: 40, program: 3)]
    #expect(byEnd.sorted() == byEnd)

    let shuffled = [byEnd[1], byPitch[1], byProgram[1], byStart[1], byEnd[0]]
    #expect(shuffled.sorted() == [byProgram[1], byEnd[0], byEnd[1], byPitch[1], byStart[1]])
}

@Test func mergeJoinsOverlappingNotesOfSamePitchAndProgram() {
    let merged = mergeOverlappingNotesWithSamePitch([
        note(0, 1, pitch: 60, amplitude: 0.8),
        note(0.5, 2, pitch: 60, amplitude: 0.2),
    ])
    #expect(merged == [note(0, 2, pitch: 60, amplitude: 0.8)])
}

@Test func mergeKeepsTwoInstrumentsOnOnePitchSeparate() {
    let input = [note(0, 1, pitch: 60, program: 0), note(0.5, 2, pitch: 60, program: 1)]
    #expect(mergeOverlappingNotesWithSamePitch(input) == input)
}

@Test func mergeLeavesNonOverlappingNotesAlone() {
    let apart = [note(0, 1, pitch: 60), note(1.5, 2, pitch: 60)]
    #expect(mergeOverlappingNotesWithSamePitch(apart) == apart)

    // Touching intervals do not overlap: a repeated note stays two notes.
    let touching = [note(0, 1, pitch: 60), note(1, 2, pitch: 60)]
    #expect(mergeOverlappingNotesWithSamePitch(touching) == touching)
}

@Test func mergeKeepsTheLaterEndWhenTheSecondNoteEndsEarlier() {
    let merged = mergeOverlappingNotesWithSamePitch([
        note(0, 2, pitch: 60),
        note(0.5, 1, pitch: 60),
    ])
    #expect(merged == [note(0, 2, pitch: 60)])
}

@Test func mergeChainsThroughAnExtendedEnd() {
    let merged = mergeOverlappingNotesWithSamePitch([
        note(0, 1, pitch: 60),
        note(0.5, 3, pitch: 60),
        note(2, 4, pitch: 60),
    ])
    #expect(merged == [note(0, 4, pitch: 60)])
}

@Test func mergeReturnsSortedOutput() {
    let merged = mergeOverlappingNotesWithSamePitch([
        note(3, 4, pitch: 60, program: 1),
        note(0.5, 2, pitch: 60, program: 0),
        note(1, 2, pitch: 55, program: 0),
        note(0, 1, pitch: 60, program: 0),
    ])
    #expect(merged == merged.sorted())
    #expect(merged == [note(0, 2, pitch: 60), note(1, 2, pitch: 55), note(3, 4, pitch: 60, program: 1)])
}

@Test func mergeOfEmptyInputIsEmpty() {
    #expect(mergeOverlappingNotesWithSamePitch([]).isEmpty)
}
