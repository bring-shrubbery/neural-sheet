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

/// The dirty rule's whole point: an edit and an undo leave the project as it was saved. The undo
/// and redo stacks are deliberately outside ``ProjectTranscription``'s equality, so the dot clears
/// again rather than sticking until the project is closed.
@Test func projectContentIgnoresUndoHistory() throws {
    let saved = makeContent()
    let savedDocument = try #require(saved.transcription).document

    var edited = savedDocument
    edited.commit(edited.delete([savedDocument.notes[0].id]))

    var withEdit = saved
    withEdit.transcription?.document = edited
    #expect(withEdit != saved)

    var undone = edited
    undone.undo()
    #expect(undone.notes == savedDocument.notes)
    // `isEdited` is sticky -- a commit sets it, an undo never clears it -- so it is not compared.
    #expect(undone.isEdited && !savedDocument.isEdited)

    var withUndo = saved
    withUndo.transcription?.document = undone
    #expect(withUndo == saved)
}
