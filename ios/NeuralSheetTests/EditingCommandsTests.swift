import Foundation
import NeuralSheetCore
import XCTest

@testable import NeuralSheet

/// The shared editing commands (iOS app design §3, item 3; sub-issue F): the batches, lists and
/// selections both apps commit, from a document and an editor state alone.
final class EditingCommandsTests: XCTestCase {
    private let piano = NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0)
    private let bass = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 40, program: 33)
    private let drum = NoteEvent(startTime: 1.5, endTime: 1.6, pitch: 36, program: NoteEvent.drumProgram)

    private var document: NoteDocument { NoteDocument(events: [piano, bass, drum]) }

    private func id(of note: NoteEvent, in document: NoteDocument) -> NoteID {
        document.notes.first { $0.note == note }!.id
    }

    // MARK: - Selection or all

    func testAnEmptySelectionMeansEveryNote() {
        let document = document
        let one = id(of: piano, in: document)

        XCTAssertEqual(EditingCommands.selectionOrAll([], in: document), Set(document.notes.map(\.id)))
        XCTAssertEqual(EditingCommands.selectionOrAll([one], in: document), [one])
    }

    // MARK: - Bulk

    func testTransposeLeavesTheDrumsAndIsTitledTranspose() {
        var document = document
        let batch = EditingCommands.transpose(in: document, selection: [], semitones: 2)

        XCTAssertEqual(batch.title, "Transpose")
        document.commit(batch)

        XCTAssertEqual(Set(document.events.map(\.pitch)), [62, 42, 36])
    }

    func testNudgeStepsOneGridDivisionWithSnapAndTenMillisecondsWithout() {
        var editor = EditorState()
        editor.grid = TempoGrid(bpm: 120)
        let document = document
        editor.selection = [id(of: piano, in: document)]
        let step = editor.grid.step(atSeconds: piano.startTime)

        var snapped = document
        snapped.commit(EditingCommands.nudge(in: document, editor: editor, steps: 1, semitones: 0, playheadSeconds: 0))
        XCTAssertEqual(snapped.note(id(of: piano, in: document))!.note.startTime, 0.5 + step, accuracy: 1e-9)

        editor.snapEnabled = false
        var free = document
        free.commit(EditingCommands.nudge(in: document, editor: editor, steps: -2, semitones: 1, playheadSeconds: 0))
        let moved = free.note(id(of: piano, in: document))!.note
        XCTAssertEqual(moved.startTime, 0.48, accuracy: 1e-9)
        XCTAssertEqual(moved.pitch, 61)
    }

    func testSnapToScaleNeedsAKey() {
        var editor = EditorState()
        XCTAssertNil(EditingCommands.snapToScale(in: document, editor: editor))

        editor.key = MusicalKey(tonic: 0, mode: .major)
        XCTAssertNotNil(EditingCommands.snapToScale(in: document, editor: editor))
    }

    func testSplitAnswersTheHalvesOnTheCallersCopy() {
        var document = document
        let (batch, halves) = EditingCommands.split(in: &document, selection: [], at: 1.55)

        XCTAssertEqual(halves.count, 4, "the bass and the drum cross 1.55 s; the piano does not")
        document.commit(batch)
        XCTAssertEqual(document.notes.count, 5)
        XCTAssertTrue(halves.allSatisfy(document.contains))
    }

    func testScaleVelocityHalvesEveryVelocity() {
        var document = document
        document.commit(EditingCommands.scaleVelocity(in: document, selection: [], percent: 50))

        XCTAssertEqual(Set(document.events.map(\.velocity)), [50])
    }

    // MARK: - Versions

    func testTheTranscriptionLeadsTheVersionRowsAndRestoresAsOneEdit() {
        var document = document
        let saved = EditingCommands.newVersion(named: "  ", document: document, existing: 0)
        XCTAssertTrue(saved.name.hasPrefix("Version 1"), "a blank name takes the default: \(saved.name)")

        let rows = EditingCommands.versionRows(rawNotes: [piano], versions: [saved])
        XCTAssertEqual(rows.map(\.noteCount), [1, 3])
        XCTAssertTrue(rows[0].isTranscription)

        let transcription = EditingCommands.version(id: NoteVersion.transcriptionID, rawNotes: [piano], versions: [saved])!
        let batch = EditingCommands.restore(transcription, in: &document)
        XCTAssertTrue(batch.title.hasPrefix("Restore"))
        document.commit(batch)
        XCTAssertEqual(document.events, [piano])

        XCTAssertEqual(EditingCommands.differences(in: document, against: saved), [])
        XCTAssertEqual(EditingCommands.comparisonSummary(document: document, comparedVersion: saved)?.missing, 2)
    }

    // MARK: - Lists

    func testAChordIsAddedOnceAndMovesInOrder() {
        var chords: [ChordEvent] = []
        let key = MusicalKey(tonic: 9, mode: .minor)

        let first = EditingCommands.addChord(&chords, at: 2, key: key)
        XCTAssertEqual(first?.index, 0)
        XCTAssertEqual(first?.inserted, true)
        XCTAssertEqual(chords.first?.chord, ChordSymbol(root: 9, quality: .minor))

        XCTAssertEqual(EditingCommands.addChord(&chords, at: 2, key: key)?.inserted, false)
        _ = EditingCommands.addChord(&chords, at: 4, key: key)
        XCTAssertEqual(EditingCommands.moveChord(&chords, from: 0, to: 6), 1)
        XCTAssertEqual(chords.map(\.seconds), [4, 6])
    }

    func testAMarkerIsAddedInsideTheTakeAndMarksItsSection() {
        var markers: [Marker] = []

        let late = EditingCommands.addMarker(&markers, at: 99, duration: 10)!
        let early = EditingCommands.addMarker(&markers, at: 2, duration: 10)!
        XCTAssertEqual(markers.map(\.seconds), [2, 10])
        XCTAssertEqual(EditingCommands.section(from: early.id, in: markers, duration: 10), 2 ..< 10)
        XCTAssertTrue(EditingCommands.moveMarker(&markers, id: late.id, to: 1, duration: 10))
        XCTAssertEqual(markers.first?.id, late.id)
    }

    // MARK: - Lyrics, confidence, clipboard

    func testALyricIsReadAgainstTheSyllableBefore() {
        var document = NoteDocument(events: [piano, NoteEvent(startTime: 1, endTime: 1.5, pitch: 62, program: 0)])
        let first = document.notes[0].id
        let second = document.notes[1].id

        document.commit(EditingCommands.lyric(in: document, id: first, typed: "hel-"))
        document.commit(EditingCommands.lyric(in: document, id: second, typed: "lo"))

        XCTAssertEqual(document.note(second)?.note.lyric?.typed, "lo")
        XCTAssertEqual(EditingCommands.pasteLyricsTargets(in: document, editor: EditorState()), [first, second])
    }

    func testOnlyAModelNoteUnderHalfIsDoubtful() {
        var doubtful = piano
        doubtful.confidence = 0.2
        let document = NoteDocument(events: [doubtful, bass])

        XCTAssertEqual(EditingCommands.doubtfulNotes(in: document, minimumLength: 0).count, 1)
        XCTAssertTrue(EditingCommands.hasDoubtfulNotes(in: document, minimumLength: 0))
    }

    func testCutIsTitledByHowManyNotesGo() {
        let document = document
        let one = id(of: piano, in: document)

        XCTAssertEqual(EditingCommands.cut(in: document, selection: [one]).title, "Cut Note")
        XCTAssertEqual(EditingCommands.cut(in: document, selection: Set(document.notes.map(\.id))).title, "Cut Notes")
        XCTAssertEqual(EditingCommands.selectedNotes(in: document, selection: [one]), [piano])
    }

    // MARK: - Selection text

    func testThePitchFieldReadsNamesAndNumbers() {
        XCTAssertEqual(SelectionText.parsePitch("C4"), 60)
        XCTAssertEqual(SelectionText.parsePitch("c#4"), 61)
        XCTAssertEqual(SelectionText.parsePitch("Db4"), 61)
        XCTAssertEqual(SelectionText.parsePitch("127"), 127)
        XCTAssertNil(SelectionText.parsePitch("H2"))
        XCTAssertNil(SelectionText.parsePitch("200"))
        XCTAssertEqual(SelectionText.confidence([piano]), "—")
    }
}
