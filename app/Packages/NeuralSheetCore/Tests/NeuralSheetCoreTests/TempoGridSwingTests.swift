import Foundation
import Testing

@testable import NeuralSheetCore

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// 120 BPM: a quarter is 0.5 s, a bar of 4/4 two seconds.
private func grid(_ division: GridDivision, swing: Double, meter: TimeSignature = .common) -> TempoGrid {
    var grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120, timeSignature: meter)], division: division)
    grid.swing = swing
    return grid
}

@Test func straightSwingReproducesTheUnswungLines() {
    for division in GridDivision.allCases {
        var straight = TempoGrid(bpm: 120, offsetSeconds: 0.1, division: division)
        let before = straight.lines(from: 0, to: 6)
        straight.swing = 0.5
        #expect(straight.lines(from: 0, to: 6) == before)
        #expect(straight.snap(1.37) == TempoGrid(bpm: 120, offsetSeconds: 0.1, division: division).snap(1.37))
    }
}

@Test func swingClampsAndDefaultsToStraight() {
    #expect(TempoGrid().swing == 0.5)
    #expect(grid(.eighth, swing: 0.9).swing == 0.75)
    #expect(grid(.eighth, swing: 0.2).swing == 0.5)
    #expect(grid(.eighth, swing: .nan).swing == 0.5)
    #expect(grid(.eighth, swing: 0.66).straight.swing == 0.5)
    #expect(grid(.eighth, swing: 0.66) != grid(.eighth, swing: 0.5))
}

@Test func aSwungEighthGridPutsTheOffBeatAtTwoThirdsOfTheBeat() {
    let lines = grid(.eighth, swing: 2.0 / 3.0).lines(from: 0, to: 1)
    let seconds = lines.map(\.seconds)

    #expect(seconds.count == 5)
    #expect(near(seconds[0], 0) && near(seconds[2], 0.5) && near(seconds[4], 1))
    #expect(near(seconds[1], 0.5 * 2 / 3))
    #expect(near(seconds[3], 0.5 + 0.5 * 2 / 3))
    #expect(lines[1].kind == .division && lines[2].kind == .beat)
}

@Test func aSwungSixteenthGridSwingsWithinEachEighth() {
    let seconds = grid(.sixteenth, swing: 0.75).lines(from: 0, to: 0.5).map(\.seconds)

    // Eighth = 0.25 s; the second sixteenth of each sits at three quarters of it.
    #expect(seconds.count == 5)
    #expect(near(seconds[1], 0.1875))
    #expect(near(seconds[2], 0.25))
    #expect(near(seconds[3], 0.4375))
}

@Test func tripletsAndCoarseDivisionsIgnoreSwing() {
    for division in [GridDivision.eighthTriplet, .sixteenthTriplet, .quarter, .half, .bar, .thirtySecond] {
        let straight = TempoGrid(bpm: 120, division: division)
        #expect(grid(division, swing: 0.7).lines(from: 0, to: 4) == straight.lines(from: 0, to: 4))
        #expect(!grid(division, swing: 0.7).swings)
    }
}

@Test func theEighthsOf68AreItsBeatsAndDoNotSwing() {
    let meter = TimeSignature(numerator: 6, denominator: 8)
    #expect(grid(.eighth, swing: 0.7, meter: meter).lines(from: 0, to: 3)
            == grid(.eighth, swing: 0.5, meter: meter).lines(from: 0, to: 3))
}

@Test func swingRestartsAtEveryBar() {
    let meter = TimeSignature(numerator: 5, denominator: 8)
    let swung = grid(.sixteenth, swing: 0.75, meter: meter)
    let lines = swung.lines(from: 0, to: 1.25)
    // A bar of 5/8 at 120 is 1.25 s: ten sixteenths, five pairs, and the next bar starts straight.
    #expect(lines.count == 11)
    #expect(near(lines[1].seconds, 0.1875))
    #expect(near(lines[10].seconds, 1.25) && lines[10].kind == .bar)

    let odd = grid(.eighth, swing: 0.75, meter: TimeSignature(numerator: 3, denominator: 4))
    // 3/4 on an eighth grid: three pairs, every off-beat swung, the next bar on its line.
    let offBeats = odd.lines(from: 0, to: 1.5).filter { $0.kind == .division }.map(\.seconds)
    #expect(offBeats.count == 3)
    #expect(near(offBeats[2], 1.0 + 0.375))
}

@Test func snapLandsOnTheSwungLine() {
    let swung = grid(.eighth, swing: 2.0 / 3.0)

    #expect(near(swung.snap(0.30), 0.5 * 2 / 3))
    #expect(near(swung.snap(0.25), 0.5 * 2 / 3))
    #expect(near(swung.snap(0.14), 0))
    #expect(near(swung.snap(0.45), 0.5))
    #expect(near(swung.snapDown(0.32), 0))
    #expect(near(swung.snapDown(0.34), 0.5 * 2 / 3))
    #expect(near(swung.snap(1.98), 2))
}

@Test func quantizeFollowsTheSwing() {
    let document = NoteDocument(events: [NoteEvent(startTime: 0.27, endTime: 0.4, pitch: 60, program: 0)])
    let batch = document.quantize(Set(document.notes.map(\.id)), grid: grid(.eighth, swing: 2.0 / 3.0), lengths: false)

    #expect(near(batch.changed[0].after.note.startTime, 0.5 * 2 / 3))
}

@Test func swingIsSavedWithTheGridAndTheProject() throws {
    let swung = grid(.sixteenth, swing: 0.6)
    let decoded = try JSONDecoder().decode(TempoGrid.self, from: JSONEncoder().encode(swung))
    #expect(decoded == swung)
    #expect(try JSONDecoder().decode(TempoGrid.self, from: Data(#"{"bpm": 100}"#.utf8)).swing == 0.5)

    var state = ProjectState()
    state.gridSwing = 0.66
    state.gridDivision = .eighth
    let restored = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state))
    #expect(restored.tempoGrid.swing == 0.66)
    #expect(try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8)).tempoGrid.swing == 0.5)
}

@Test func theScoreQuantizesToTheStraightGrid() {
    let notes = [NoteEvent(startTime: 0.25, endTime: 0.5, pitch: 60, program: 0)]
    let swung = MusicXMLWriter.data(notes: notes, grid: grid(.eighth, swing: 0.75))
    let straight = MusicXMLWriter.data(notes: notes, grid: grid(.eighth, swing: 0.5))

    #expect(swung == straight)
}
