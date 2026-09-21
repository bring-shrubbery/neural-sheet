import Foundation
import Testing

@testable import NeuralSheetCore

private func makeContent() -> ProjectContent {
    let raw = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)]

    return ProjectContent(
        transcription: ProjectTranscription(sourceSampleCount: 16_000, rawNotes: raw, document: NoteDocument(events: raw)),
        selectedGroups: [0, 36],
        mixer: [0: InstrumentChannelSettings(gainDb: -3, muted: false, soloed: false)],
        exportTempo: 120,
        gridOffsetSeconds: 0,
        gridDivision: .sixteenth,
        snapEnabled: true,
        targetProgram: 0)
}

@Test func projectContentIsEqualForTheSameState() {
    #expect(makeContent() == makeContent())
}

@Test func projectContentDiffersPerField() {
    var mix = makeContent()
    mix.mixer[0]?.muted = true
    #expect(mix != makeContent())

    var tempo = makeContent()
    tempo.exportTempo = 90
    #expect(tempo != makeContent())

    var groups = makeContent()
    groups.selectedGroups = []
    #expect(groups != makeContent())

    var snap = makeContent()
    snap.snapEnabled = false
    #expect(snap != makeContent())

    var target = makeContent()
    target.targetProgram = 128
    #expect(target != makeContent())

    var notes = makeContent()
    notes.transcription = nil
    #expect(notes != makeContent())
}
