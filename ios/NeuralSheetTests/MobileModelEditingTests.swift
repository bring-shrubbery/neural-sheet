import Foundation
import NeuralSheetCore
import UIKit
import XCTest

@testable import NeuralSheet

/// Editing through the model's public contract (sub-issue F): move, resize, insert, delete and the
/// card's fields each commit one batch, and undo has one source of truth -- the document's stack,
/// which the undo manager's entries drive, so the system's undo and the bottom bar's stay in step.
@MainActor
final class MobileModelEditingTests: XCTestCase {
    private let first = NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0)
    private let second = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 64, program: 0)

    private var undoManager: UndoManager!

    /// A model over eight seconds of silence and two notes, with an undo manager that groups by
    /// hand (`step`), as the run loop groups each touch in the app.
    private func makeModel() -> MobileModel {
        let take = SourceAudio(deviceRate: 48_000, channels: [[Float](repeating: 0, count: 8 * 48_000)],
                               mono16k: [Float](repeating: 0, count: 8 * 16_000),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)
        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: [first, second])
        model.editor.grid = TempoGrid(bpm: 120)

        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        return model
    }

    /// One user action: one undo group, as one touch is in the app.
    private func step(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    private func id(of note: NoteEvent, in model: MobileModel) throws -> NoteID {
        try XCTUnwrap(model.document?.notes.first { $0.note == note }?.id)
    }

    func testAMoveCommitsOneBatchThatBothUndosTakeBack() throws {
        let model = makeModel()
        let moved = try id(of: first, in: model)

        step { model.moveNotes([moved], deltaSeconds: 0.5, deltaSemitones: 2) }

        XCTAssertEqual(model.document?.note(moved)?.note.pitch, 62)
        XCTAssertEqual(model.document?.note(moved)?.note.startTime ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.undoTitle, "Move Note")
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Move Note")

        // The system's undo (three-finger swipe, shake) runs the document's.
        undoManager.undo()
        XCTAssertEqual(model.document?.note(moved)?.note, first)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)
        XCTAssertTrue(undoManager.canRedo)

        // The bar's Redo goes through the manager too, so neither stack falls behind.
        model.redo()
        XCTAssertEqual(model.document?.note(moved)?.note.pitch, 62)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)

        model.undo()
        XCTAssertEqual(model.document?.note(moved)?.note, first)
        XCTAssertEqual(model.document?.canUndo, false)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testResizeInsertAndDeleteAreEachOneUndoStep() throws {
        let model = makeModel()
        let resized = try id(of: second, in: model)

        step { model.resizeNotes([resized], edge: .end, deltaSeconds: 0.5) }
        XCTAssertEqual(model.document?.note(resized)?.note.endTime ?? 0, 2.5, accuracy: 1e-9)

        let drawn = NoteEvent(startTime: 4, endTime: 4.25, pitch: 67, program: 0)
        step { model.insertNote(drawn) }
        XCTAssertEqual(model.document?.notes.count, 3)
        XCTAssertEqual(model.selectedNotes, [drawn], "the drawn note is selected")

        step { model.deleteSelection() }
        XCTAssertEqual(model.document?.notes.count, 2)
        XCTAssertTrue(model.editor.selection.isEmpty, "the deleted note leaves the selection")

        undoManager.undo()
        XCTAssertEqual(model.document?.notes.count, 3)
        undoManager.undo()
        XCTAssertEqual(model.document?.notes.count, 2)
        undoManager.undo()
        XCTAssertEqual(model.document?.note(resized)?.note, second)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertFalse(model.canUndo)
    }

    func testTheCardsFieldsWriteTheWholeSelection() throws {
        let model = makeModel()
        model.selectAll()

        step { model.setSelectionPitch(72) }
        XCTAssertEqual(Set(model.selectedNotes.map(\.pitch)), [72])

        step { model.setSelectionVelocity(40) }
        XCTAssertEqual(Set(model.selectedNotes.map(\.velocity)), [40])

        step { model.setSelectionProgram(33) }
        XCTAssertEqual(Set(model.selectedNotes.map(\.program)), [33])
        XCTAssertEqual(model.editor.targetProgram, 33, "the instrument last assigned is the one drawn in next")

        step { model.setSelectionLength(0.25) }
        XCTAssertEqual(Set(model.selectedNotes.map { ($0.endTime - $0.startTime).rounded(toPlaces: 6) }), [0.25])

        model.setSelection([try XCTUnwrap(model.document?.notes.first?.id)])
        step { model.setSelectedLyric("la") }
        XCTAssertEqual(model.selectedNotes.first?.lyric?.typed, "la")
    }

    func testWithoutAnUndoManagerTheBarStillUndoesTheDocument() throws {
        let model = makeModel()
        model.undoManager = nil
        let moved = try id(of: first, in: model)

        model.moveNotes([moved], deltaSeconds: 0, deltaSemitones: -1)
        model.undo()

        XCTAssertEqual(model.document?.note(moved)?.note, first)
        model.redo()
        XCTAssertEqual(model.document?.note(moved)?.note.pitch, 59)
    }

    func testNothingCommitsWhileARunStreams() throws {
        let model = makeModel()
        model.streamRawNotes([first])

        model.insertNote(second)
        XCTAssertNil(model.document)
        XCTAssertFalse(model.canEdit)
    }

    func testRestoringTheTranscriptionUndoesAsOneEdit() throws {
        let model = makeModel()
        let moved = try id(of: first, in: model)

        step { model.moveNotes([moved], deltaSeconds: 0, deltaSemitones: 5) }
        step { model.restoreVersion(id: NoteVersion.transcriptionID) }
        XCTAssertEqual(model.document?.events, [first, second])
        XCTAssertTrue(model.undoTitle?.hasPrefix("Restore") ?? false)

        undoManager.undo()
        XCTAssertEqual(model.document?.note(moved)?.note.pitch, 65)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))

        return (self * scale).rounded() / scale
    }
}
