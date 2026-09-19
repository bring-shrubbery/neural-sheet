import CoreGraphics
import Testing

@testable import NeuralSheetCore

@Test func hitZonesAreTheOuterEdgesOfWideNotesOnly() {
    let rect = CGRect(x: 100, y: 10, width: 40, height: 8)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 103, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .startEdge)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 137, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .endEdge)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 120, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .body)
    #expect(EditGestureMath.hitZone(in: rect, at: CGPoint(x: 120, y: 30), edgeWidth: 6, minimumWidthForEdges: 14) == nil)

    let narrow = CGRect(x: 100, y: 10, width: 10, height: 8)
    #expect(EditGestureMath.hitZone(in: narrow, at: CGPoint(x: 101, y: 14), edgeWidth: 6, minimumWidthForEdges: 14) == .body)
}

@Test func moveSnapsTheAnchorAndLocksAnAxis() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)   // 0.5 s
    let snapped = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: grid, axisLock: nil)
    #expect(abs(snapped.seconds - 0.4) < 1e-9, "1.1 + 0.3 = 1.4 snaps to 1.5")
    #expect(snapped.semitones == 2)

    let free = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: nil)
    #expect(free.seconds == 0.3)

    let timeOnly = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: .timeOnly)
    #expect(timeOnly.semitones == 0 && timeOnly.seconds == 0.3)

    let pitchOnly = EditGestureMath.resolveMove(deltaSeconds: 0.3, deltaSemitones: 2, anchorStart: 1.1, grid: nil, axisLock: .pitchOnly)
    #expect(pitchOnly.seconds == 0 && pitchOnly.semitones == 2)

    #expect(EditGestureMath.axisLock(deltaX: 10, deltaY: 3) == .timeOnly)
    #expect(EditGestureMath.axisLock(deltaX: 2, deltaY: 30) == .pitchOnly)
}

@Test func resizeSnapsTheDraggedEdge() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)
    #expect(abs(EditGestureMath.resolveResize(deltaSeconds: 0.2, anchorEdgeTime: 2.0, grid: grid) - 0) < 1e-9)
    #expect(abs(EditGestureMath.resolveResize(deltaSeconds: 0.3, anchorEdgeTime: 2.0, grid: grid) - 0.5) < 1e-9)
    #expect(EditGestureMath.resolveResize(deltaSeconds: 0.3, anchorEdgeTime: 2.0, grid: nil) == 0.3)
}

@Test func drawnNoteStartsOnTheLineBeforeTheClickAndIsAtLeastOneDivision() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)
    let click = EditGestureMath.drawnNote(anchor: 1.3, current: 1.3, grid: grid, snapEnabled: true)
    #expect(abs(click.start - 1.0) < 1e-9 && abs(click.end - 1.5) < 1e-9)

    let dragged = EditGestureMath.drawnNote(anchor: 1.3, current: 2.4, grid: grid, snapEnabled: true)
    #expect(abs(dragged.end - 2.5) < 1e-9)

    let backwards = EditGestureMath.drawnNote(anchor: 1.3, current: 0.2, grid: grid, snapEnabled: true)
    #expect(abs(backwards.end - 1.5) < 1e-9)

    let unsnapped = EditGestureMath.drawnNote(anchor: 1.3, current: 1.3, grid: grid, snapEnabled: false)
    #expect(unsnapped.start == 1.3 && abs(unsnapped.end - 1.8) < 1e-9)
}

@Test func marqueeSelectsEveryIntersectingNote() {
    let notes: [(id: NoteID, rect: CGRect)] = [
        (NoteID(0), CGRect(x: 0, y: 0, width: 10, height: 5)),
        (NoteID(1), CGRect(x: 8, y: 0, width: 10, height: 5)),
        (NoteID(2), CGRect(x: 50, y: 50, width: 10, height: 5)),
    ]
    let rect = CGRect(x: 9, y: 1, width: 20, height: 20)
    #expect(EditGestureMath.marqueeSelection(rect, notes: notes) == [NoteID(0), NoteID(1)])

    // A marquee dragged up-and-left is the same rectangle.
    let flipped = CGRect(x: 29, y: 21, width: -20, height: -20)
    #expect(EditGestureMath.marqueeSelection(flipped, notes: notes) == [NoteID(0), NoteID(1)])
}
