import Testing

@testable import NeuralSheetCore

@Test func aPlainRunIsOnePassWithTheSelection() {
    let selected: [InstrumentGroup] = [.acousticPiano, .drums]
    let passes = TranscriptionPlan.passes(selected: selected, stems: false)

    #expect(passes == [TranscriptionPass(stem: nil, groups: selected)])
    #expect(passes[0].engineGroups == [0, 36])
}

@Test func anAutomaticPlainRunDecodesEverything() {
    let passes = TranscriptionPlan.passes(selected: [], stems: false)

    #expect(passes.count == 1)
    #expect(passes[0].engineGroups.isEmpty)
}

@Test func eachStemGetsTheInstrumentsItCanHold() {
    let passes = TranscriptionPlan.passes(selected: [], stems: true)

    #expect(passes.map(\.stem) == [0, 1, 2, 3])
    #expect(passes[0].groups == [.drums])
    #expect(passes[1].groups == [.acousticBass, .electricBass])
    #expect(passes[3].groups == [.voice])

    // Automatic: the rest is every named group but the four the other stems hold.
    let other = passes[2].groups
    #expect(other.count == InstrumentGroup.allCases.count - 4)
    #expect(!other.contains(.drums) && !other.contains(.voice))
    #expect(!other.contains(.acousticBass) && !other.contains(.electricBass))
    #expect(other.first == .acousticPiano)
}

@Test func theOtherStemKeepsTheSelectionLessTheReservedGroups() {
    let selected: [InstrumentGroup] = [.acousticPiano, .electricBass, .voice, .violin, .drums]

    #expect(TranscriptionPlan.stemGroups(stem: 2, selected: selected) == [.acousticPiano, .violin])
    // The fixed stems ignore the selection.
    #expect(TranscriptionPlan.stemGroups(stem: 0, selected: [.violin]) == [.drums])
    #expect(TranscriptionPlan.stemGroups(stem: 3, selected: [.violin]) == [.voice])
}

@Test func aStemsRunFillsTheBarInOrder() {
    let passes = TranscriptionPlan.passes(selected: [], stems: true)

    #expect(TranscriptionPlan.separationProgress(0) == 0)
    #expect(TranscriptionPlan.separationProgress(1) == 0.5)
    #expect(passes[0].overallProgress(0) == 0.5)
    #expect(passes[0].overallProgress(1) == 0.625)
    #expect(passes[3].overallProgress(0) == 0.875)
    #expect(passes[3].overallProgress(1) == 1)

    let plain = TranscriptionPlan.passes(selected: [], stems: false)[0]
    #expect(plain.overallProgress(0.3) == 0.3)
}

@Test func theLandingAppliesTheAfterTranscriptionSettings() {
    var settings = GlobalSettings()
    settings.minimumNoteLength = 0.05
    settings.minimumConfidence = 0.5

    let notes = [
        NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0, confidence: 0.9),
        NoteEvent(startTime: 1, endTime: 1.01, pitch: 62, program: 0, confidence: 0.9),
        NoteEvent(startTime: 2, endTime: 3, pitch: 64, program: 0, confidence: 0.2),
    ]

    #expect(NoteEvent.landing(notes, settings: settings) == [notes[0]])
    #expect(NoteEvent.landing(notes, settings: GlobalSettings()) == notes)
}
