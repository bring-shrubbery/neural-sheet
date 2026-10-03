import Foundation
import NeuralSheetCore
import UIKit
import XCTest

@testable import NeuralSheet

/// The touch score's inputs (sub-issue G): for a known two-part take with a meter change, the
/// score the screen builds and lays out has the systems and the time signatures the Mac's
/// `ScoreContainerView` gets for the same inputs (the model code is shared, so this guards what
/// the port feeds it), a time maps to a measure and back across a tempo change, and the part
/// sheet's commands change the arrangement as the Mac's card does, with an undo.
@MainActor
final class ScoreScreenTests: XCTestCase {
    /// Piano and a steel-string guitar shown as notation and tab, on a grid that goes from 4/4 at
    /// 120 to 3/4 at 90 at bar 3.
    static func fixture() -> MobileModel {
        let seconds = 8.0
        let rate = 48000.0
        let silence = [Float](repeating: 0, count: Int(seconds * rate))
        let take = SourceAudio(deviceRate: rate, channels: [silence, silence],
                               mono16k: [Float](repeating: 0, count: Int(seconds * 16000)),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)

        var notes: [NoteEvent] = []
        for i in 0 ..< 14 {
            let start = Double(i) * 0.5
            notes.append(NoteEvent(startTime: start, endTime: start + 0.45, pitch: 60 + (i * 2) % 12, program: 0))
            notes.append(NoteEvent(startTime: start + 0.25, endTime: start + 0.5, pitch: 45 + (i * 5) % 12, program: 25))
        }

        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: notes)
        model.editor.grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120),
                                                 GridSegment(startBar: 3, bpm: 90, timeSignature: TimeSignature(numerator: 3, denominator: 4))],
                                      offsetSeconds: 0)

        var guitar = PartDisplay()
        let template = TabTemplate.template(forProgram: 25)!
        guitar.tab = template.setup(preset: template.presets[0])
        guitar.mode = .both
        model.arrangement.parts[25] = guitar

        return model
    }

    private func layOut(_ model: MobileModel, width: CGFloat) -> ScoreTouchView {
        let view = ScoreTouchView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        view.sync()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        return view
    }

    /// The Mac's numbers for these inputs at scale 1, from `ScoreLayout` built in the Mac target:
    /// four systems of a measure each at 390 points (an iPhone's portrait width), two of two
    /// measures at 760.
    func testTheLayoutHasTheMacsSystems() throws {
        let model = Self.fixture()

        let phone = layOut(model, width: 390)
        let phoneLayout = try XCTUnwrap(phone.canvas.painter.layout)
        XCTAssertEqual(phoneLayout.systems.map { $0.measures.map(\.index) }, [[0], [1], [2], [3]])

        let wide = layOut(model, width: 760)
        XCTAssertEqual(try XCTUnwrap(wide.canvas.painter.layout).systems.map { $0.measures.map(\.index) }, [[0, 1], [2, 3]])

        // Both parts, the guitar with its tab staff.
        let document = phone.canvas.painter.document
        XCTAssertEqual(document.parts.map(\.program), [0, 25])
        XCTAssertNotNil(document.parts[1].tab)

        // The first measure opens in 4/4 with its time signature shown; bar 3 changes to 3/4.
        XCTAssertEqual(document.bars.first?.timeSignature, TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(phoneLayout.systems.first?.measures.first?.index, 0)
        XCTAssertEqual(phoneLayout.systems.first?.showsTimeSignature, true)
        XCTAssertEqual(document.bars[2].timeSignature, TimeSignature(numerator: 3, denominator: 4))
        XCTAssertTrue(document.bars[2].showsTimeSignature)

        // The screen's document is the one the shared builder makes from the model's state.
        XCTAssertEqual(document, ArrangementCommands.scoreDocument(notes: model.document!.events,
                                                                   ids: model.document!.notes.map { Optional($0.id) },
                                                                   editor: model.editor, arrangement: model.arrangement))
    }

    /// Tap to seek goes through `seconds(atMeasure:units:)`, the cursor through
    /// `measureIndex(atSeconds:)`: either side of the tempo change (bar 3 starts at 4 s), one
    /// undoes the other.
    func testMeasuresAndSecondsRoundTripAcrossTheTempoChange() throws {
        let model = Self.fixture()
        let document = model.scoreDocument()
        let grid = model.editor.grid

        for seconds in [0.3, 1.75, 3.9, 4.0, 4.4, 5.3, 6.95] {
            let position = try XCTUnwrap(document.measureIndex(atSeconds: seconds, grid: grid), "\(seconds)")
            XCTAssertEqual(document.seconds(atMeasure: position.measure, units: position.units, grid: grid), seconds,
                           accuracy: 1e-9, "\(seconds)")
        }

        XCTAssertEqual(document.measureIndex(atSeconds: 4.0, grid: grid)?.measure, 2)
        XCTAssertEqual(document.measureIndex(atSeconds: 4.0, grid: grid)?.units ?? -1, 0, accuracy: 1e-9)
    }

    /// Tab on a part with no template gives it the guitar's, as the Mac's card does; the change
    /// is one undo.
    func testThePartSheetChangesTheArrangementWithAnUndo() {
        let model = Self.fixture()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        undoManager.beginUndoGrouping()
        model.setPartMode(.tab, program: 0)
        undoManager.endUndoGrouping()

        XCTAssertEqual(model.arrangement.display(for: 0).mode, .tab)
        XCTAssertEqual(model.arrangement.display(for: 0).tab?.template, TabTemplate.all.first?.id)

        undoManager.beginUndoGrouping()
        model.setPartTransposition(99, program: 0)
        undoManager.endUndoGrouping()
        XCTAssertEqual(model.arrangement.display(for: 0).transposition, 36)

        undoManager.undo()
        undoManager.undo()
        XCTAssertNil(model.arrangement.parts[0])
    }
}
