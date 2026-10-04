import Foundation
import NeuralSheetCore
import UIKit
import XCTest

@testable import NeuralSheet

/// The touch views as VoiceOver reads them (sub-issue J): the timeline lists the ruler, the keys
/// and the roll, whose notes read as the Mac reads them and carry its actions; the ruler steps
/// the playhead a beat; the score reads a heading per system and its notes in order.
@MainActor
final class AccessibilityElementsTests: XCTestCase {
    private let first = NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0)
    private let second = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 64, program: 0)

    private func makeTimeline() -> (MobileModel, TimelineTouchView) {
        let take = SourceAudio(deviceRate: 48_000, channels: [[Float](repeating: 0, count: 8 * 48_000)],
                               mono16k: [Float](repeating: 0, count: 8 * 16_000),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)
        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: [first, second])
        model.editor.grid = TempoGrid(bpm: 120)
        model.zoomLevel = 4

        let view = TimelineTouchView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        view.sync()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        return (model, view)
    }

    private func notes(of view: TimelineTouchView) -> [DrawnTouchElement] {
        (view.roll.accessibilityElements ?? []).compactMap { $0 as? DrawnTouchElement }
    }

    func testTheTimelineReadsTheRulerTheKeysThenTheNotesInTimeOrder() throws {
        let (_, view) = makeTimeline()
        let children = try XCTUnwrap(view.accessibilityElements)

        XCTAssertEqual(children.count, 3)
        XCTAssertTrue(children[0] as? DrawnTouchElement === view.accessibilityRuler)
        XCTAssertTrue(children[1] as? DrawnTouchElement === view.accessibilityKeyboard)
        XCTAssertTrue(children[2] as? UIView === view.roll)

        let notes = notes(of: view)
        XCTAssertEqual(notes.count, 2)
        // At 120 BPM in 4/4 a beat is half a second: the first note starts on beat 2 of bar 1 and
        // lasts a beat; the second starts on beat 3 and lasts two.
        let label = try XCTUnwrap(notes[0].accessibilityLabel)
        XCTAssertTrue(label.hasPrefix("C4, "), label)
        XCTAssertTrue(label.contains("bar 1 beat 2"), label)
        XCTAssertTrue(try XCTUnwrap(notes[1].accessibilityLabel).hasPrefix("E4, "))
        XCTAssertTrue(notes[0].accessibilityTraits.contains(.button))
    }

    func testANoteIsSelectedAsTheOutlineShowsAndItsActionsEditIt() throws {
        let (model, view) = makeTimeline()
        let element = try XCTUnwrap(notes(of: view).first)

        XCTAssertFalse(element.accessibilityTraits.contains(.selected))
        XCTAssertTrue(element.accessibilityActivate())
        view.sync()
        XCTAssertTrue(element.accessibilityTraits.contains(.selected))
        XCTAssertEqual(model.selectedNotes.map(\.pitch), [60])

        let actions = try XCTUnwrap(element.accessibilityCustomActions)
        XCTAssertEqual(actions.map(\.name), ["Select", "Delete", "Open Note Card", "Move Left", "Move Right", "Move Up", "Move Down"])

        let up = try XCTUnwrap(actions.first { $0.name == "Move Up" })
        XCTAssertTrue(up.actionHandler?(up) ?? false)
        XCTAssertEqual(model.document?.events.map(\.pitch).sorted(), [61, 64])
    }

    func testTheRulerStepsThePlayheadABeatAndReadsItsBarAndBeat() throws {
        let (model, view) = makeTimeline()
        let ruler = view.accessibilityRuler

        XCTAssertTrue(ruler.accessibilityTraits.contains(.adjustable))
        ruler.accessibilityIncrement()
        XCTAssertEqual(model.engine.playheadSeconds, 0.5, accuracy: 1e-6)
        XCTAssertTrue(try XCTUnwrap(ruler.accessibilityValue).contains("bar 1 beat 2"))

        ruler.accessibilityDecrement()
        XCTAssertEqual(model.engine.playheadSeconds, 0, accuracy: 1e-6)
    }

    func testTheKeyboardIsAdjustableAndReadsTheKeysOnShow() throws {
        let (_, view) = makeTimeline()
        let keyboard = view.accessibilityKeyboard

        XCTAssertTrue(keyboard.accessibilityTraits.contains(.adjustable))
        XCTAssertTrue(try XCTUnwrap(keyboard.accessibilityValue).contains(" to "))
    }

    func testTheScoreReadsAHeadingPerSystemThenItsNotes() throws {
        let model = ScoreScreenTests.fixture()
        let view = ScoreTouchView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.sync()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let elements = try XCTUnwrap(view.accessibilityElements as? [DrawnTouchElement])
        let headings = elements.filter { $0.accessibilityTraits.contains(.header) }

        XCTAssertEqual(headings.first?.accessibilityLabel, "System 1, bars 1 to 1")
        XCTAssertTrue(elements.first === headings.first)
        XCTAssertEqual(headings.count, view.canvas.painter.layout?.systems.count)

        let note = try XCTUnwrap(elements.first { $0.accessibilityTraits.contains(.button) })
        XCTAssertTrue(try XCTUnwrap(note.accessibilityLabel).hasSuffix("bar 1"))
        XCTAssertEqual(note.accessibilityCustomActions?.map(\.name), ["Open Part Card"])
    }
}
