import Foundation
import NeuralSheetCore
import UIKit
import XCTest

@testable import NeuralSheet

/// The touch roll's edit targets (sub-issue F): a selected note's end handles are at least 22 pt
/// wide and the minimum hit target tall, and only a selected note is a drag target.
@MainActor
final class TimelineEditingTests: XCTestCase {
    private let first = NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0)
    private let second = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 64, program: 0)

    private func makeModel() -> MobileModel {
        let take = SourceAudio(deviceRate: 48_000, channels: [[Float](repeating: 0, count: 8 * 48_000)],
                               mono16k: [Float](repeating: 0, count: 8 * 16_000),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)
        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: [first, second])
        model.editor.grid = TempoGrid(bpm: 120)

        return model
    }

    private func id(of note: NoteEvent, in model: MobileModel) throws -> NoteID {
        try XCTUnwrap(model.document?.notes.first { $0.note == note }?.id)
    }

    func testASelectedNotesEndHandlesAreAtLeast22PointsWideAndResize() throws {
        let model = makeModel()
        model.zoomLevel = 4
        model.setSelection([try id(of: second, in: model)])

        let view = TimelineTouchView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        view.sync()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let rect = try XCTUnwrap(view.roll.painter.noteRect(second, height: view.roll.bounds.height))
        let handles = RollBandView.handleRects(for: rect)
        XCTAssertGreaterThanOrEqual(handles.start.width, 22)
        XCTAssertGreaterThanOrEqual(handles.end.width, 22)
        XCTAssertGreaterThanOrEqual(handles.end.height, TimelineTouchView.minimumHitTarget)

        XCTAssertEqual(view.selectedNoteHit(at: CGPoint(x: rect.maxX + 6, y: rect.midY))?.zone, .endEdge)
        XCTAssertEqual(view.selectedNoteHit(at: CGPoint(x: rect.minX - 6, y: rect.midY))?.zone, .startEdge)
        XCTAssertEqual(view.selectedNoteHit(at: CGPoint(x: rect.midX, y: rect.midY))?.zone, .body)

        // The unselected note is not a drag target: a drag there pans.
        let other = try XCTUnwrap(view.roll.painter.noteRect(first, height: view.roll.bounds.height))
        XCTAssertNil(view.selectedNoteHit(at: CGPoint(x: other.midX, y: other.midY)))
    }
}
