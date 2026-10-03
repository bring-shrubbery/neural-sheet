import Foundation
import NeuralSheetCore
import UIKit
import XCTest

@testable import NeuralSheet

/// The touch timeline's use of the shared geometry (sub-issue E): for a known take, laid out at a
/// known size, a bar line and C4's lane land where the Mac's `TimelineGeometry` puts them for the
/// same inputs, and the bands that draw them line up on screen -- the roll with the ruler in
/// time, the roll with the keyboard in pitch.
@MainActor
final class TimelineGeometryPortTests: XCTestCase {
    private func layOut() -> TimelineTouchView {
        let seconds = 8.0
        let rate = 48000.0
        let silence = [Float](repeating: 0, count: Int(seconds * rate))
        let take = SourceAudio(deviceRate: rate, channels: [silence, silence],
                               mono16k: [Float](repeating: 0, count: Int(seconds * 16000)),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)

        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: [NoteEvent(startTime: 0.5, endTime: 1, pitch: 60, program: 0),
                                         NoteEvent(startTime: 1, endTime: 2, pitch: 76, program: 0),
                                         NoteEvent(startTime: 2, endTime: 3, pitch: 48, program: 33)])
        model.editor.grid = TempoGrid(bpm: 120)
        model.zoomLevel = 2

        let view = TimelineTouchView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        view.sync()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        return view
    }

    /// The Mac's geometry, configured from the inputs the touch view was given: the scale, the
    /// zoom, the take, the column it measured, and the pitch range and scroll it settled on.
    private func macGeometry(like touch: TimelineGeometry) -> TimelineGeometry {
        let mac = TimelineGeometry()
        mac.scale = 1
        mac.zoom = 2
        mac.duration = 8
        mac.viewportWidth = 390 - TimelineMetrics.gutterWidth
        mac.waveformHeight = TimelineMetrics.waveformHeightEdit
        mac.keyboardHeight = 640 - (TimelineMetrics.waveformHeightEdit + TimelineMetrics.rulerHeight)
        mac.pitchRange = touch.pitchRange
        mac.rowHeight = touch.rowHeight
        mac.firstKey = touch.firstKey
        mac.settleFirstKey()

        return mac
    }

    func testABarLineLandsWhereTheMacGeometryPutsIt() throws {
        let view = layOut()
        let mac = macGeometry(like: view.geometry)

        XCTAssertEqual(view.geometry.zoom, 2, accuracy: 1e-9)
        XCTAssertEqual(view.geometry.rollY, mac.rollY)

        // Bar 3 at 120 BPM in 4/4 starts at 4 s: 800 points in at zoom 2.
        let bar3 = try XCTUnwrap(TempoGrid(bpm: 120).beatLines(from: 0, to: 8).filter { $0.kind == .bar }.dropFirst(2).first)
        XCTAssertEqual(bar3.seconds, 4, accuracy: 1e-9)
        XCTAssertEqual(view.geometry.x(forSeconds: bar3.seconds), mac.x(forSeconds: bar3.seconds))
        XCTAssertEqual(mac.x(forSeconds: bar3.seconds), 800)

        // On screen the roll's line and the ruler's tick are the same x, the scroll included.
        let inRoll = view.roll.convert(CGPoint(x: 800, y: 0), to: view)
        let inRuler = view.ruler.convert(CGPoint(x: 800, y: 0), to: view)
        XCTAssertEqual(inRoll.x, inRuler.x, accuracy: 1e-6)
        XCTAssertEqual(inRoll.x, TimelineMetrics.gutterWidth + 800 - view.scrollView.contentOffset.x, accuracy: 1e-6)
    }

    func testC4sLaneLandsWhereTheMacGeometryPutsIt() {
        let view = layOut()
        let mac = macGeometry(like: view.geometry)

        XCTAssertEqual(view.geometry.keyboardHeight, mac.keyboardHeight)
        XCTAssertTrue(view.geometry.pitchRange.low <= 48 && view.geometry.pitchRange.high >= 76)
        XCTAssertEqual(view.geometry.y(forPitch: 60), mac.y(forPitch: 60))
        XCTAssertEqual(view.geometry.lane(forPitch: 60).height, mac.lane(forPitch: 60).height)
        XCTAssertEqual(view.geometry.keyRect(60), mac.keyRect(60))

        // On screen C4's lane in the roll is level with C4's lane beside the keys.
        let y = view.geometry.y(forPitch: 60)
        let inRoll = view.roll.convert(CGPoint(x: view.roll.bounds.minX, y: y), to: view)
        let inKeys = view.keyboard.convert(CGPoint(x: 0, y: y), to: view)
        XCTAssertEqual(inRoll.y, inKeys.y, accuracy: 1e-6)
    }
}
