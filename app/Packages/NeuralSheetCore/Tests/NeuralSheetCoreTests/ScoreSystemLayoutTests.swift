import Foundation
import Testing

@testable import NeuralSheetCore

private let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)

private func quarters(_ count: Int, program: Int = 0, pitch: Int = 67) -> [NoteEvent] {
    (0..<count).map { NoteEvent(startTime: Double($0) * 0.5, endTime: Double($0) * 0.5 + 0.5, pitch: pitch, program: program) }
}

@Test func systemsWrapToTheWidthAndFillIt() {
    let score = ScoreDocument.build(notes: quarters(32), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 600, sp: 8)

    #expect(layout.systems.count > 1)
    #expect(layout.systems.flatMap(\.measures).map(\.index) == Array(0..<8))
    for system in layout.systems.dropLast() {
        #expect(abs(system.frame.maxX - (600 - ScoreSystemLayout.rightMargin * 8)) < 0.5, "every system but the last fills the width")
    }
    #expect(layout.totalHeight > layout.systems.last!.frame.maxY)
}

@Test func rowsStackStavesAndTabs() {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.tab = TabTemplate.template(id: "guitar")!.setup(preset: TabTemplate.template(id: "guitar")!.presets[0])
    arrangement.parts[24] = guitar

    let score = ScoreDocument.build(notes: quarters(4, program: 24, pitch: 64) + quarters(4, program: 0, pitch: 72), grid: grid, key: nil, arrangement: arrangement)
    let layout = ScoreSystemLayout(document: score, arrangement: arrangement, width: 900, sp: 8)
    let rows = layout.systems[0].rows

    #expect(rows.count == 3, "the piano's staff, the guitar's staff, the guitar's tab")
    #expect(rows[0].partIndex == 0)
    #expect(rows[1].partIndex == 1 && rows[1].kind == .staff(index: 0, clef: .treble))
    #expect(rows[2].partIndex == 1 && rows[2].kind == .tab)
    #expect(abs(rows[2].height - 5 * 1.5 * 8) < 0.01, "six lines, 1.5 spaces apart")
    #expect(rows[2].bottomLineY > rows[1].bottomLineY)
    #expect(layout.systems[0].staffBottom == rows[2].bottomLineY)
}

@Test func aSystemOffsetsAsAWhole() {
    let score = ScoreDocument.build(notes: quarters(4), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 600, sp: 8)
    let system = layout.systems[0]
    let moved = system.offset(by: 100)

    #expect(moved.frame.minY == system.frame.minY + 100)
    #expect(moved.rows[0].bottomLineY == system.rows[0].bottomLineY + 100)
    #expect(moved.measures[0].x == system.measures[0].x, "x is untouched")
}

@Test func aSystemShiftsSideways() {
    let score = ScoreDocument.build(notes: quarters(4), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 600, sp: 8)
    let system = layout.systems[0]
    let moved = system.offsetX(by: 50)

    #expect(moved.frame.minX == system.frame.minX + 50)
    #expect(moved.frame.minY == system.frame.minY, "y is untouched")
    #expect(moved.rows[0].bottomLineY == system.rows[0].bottomLineY)
    #expect(moved.measures[0].x == system.measures[0].x + 50)
    #expect(moved.measures[0].contentX == system.measures[0].contentX + 50)
    #expect(moved.measures[0].onsets.map(\.units) == system.measures[0].onsets.map(\.units))
    #expect(moved.measures[0].onsets.map(\.x) == system.measures[0].onsets.map { $0.x + 50 })
}

@Test func measurePositionsInvert() {
    let score = ScoreDocument.build(notes: quarters(8), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 900, sp: 8)
    let (_, box) = layout.box(forMeasure: 1)!
    let x = box.x(forUnits: 36)
    #expect(abs(box.units(forX: x) - 36) < 0.01)
    #expect(layout.hitTest(CGPoint(x: x, y: layout.systems[0].frame.midY))?.measure == 1)
}

@Test func thePrefixReservesTheWrittenKeySignature() {
    // A project in C with a trumpet written a tone up: the part's signature has two sharps
    // although the project key has none, and the prefix must make room for them.
    var arrangement = ScoreArrangement()
    var trumpet = PartDisplay()
    trumpet.transposition = 2
    arrangement.parts[56] = trumpet

    let score = ScoreDocument.build(notes: quarters(4, program: 56, pitch: 67), grid: grid,
                                    key: MusicalKey(tonic: 0, mode: .major), arrangement: arrangement)
    #expect(score.fifths == 0)
    #expect(score.parts[0].writtenFifths == 2)
    #expect(score.parts[0].staves.count == 1)

    let sp: CGFloat = 8
    let layout = ScoreSystemLayout(document: score, arrangement: arrangement, width: 900, sp: sp)
    let box = layout.systems[0].measures[0]
    let needed = (ScoreSystemLayout.clefWidth + ScoreSystemLayout.timeSignatureWidth + 2 * ScoreSystemLayout.accidentalWidth) * sp

    #expect(box.contentX - box.x >= needed - 0.01, "the clef, two sharps and the time signature fit before the first note")
}
