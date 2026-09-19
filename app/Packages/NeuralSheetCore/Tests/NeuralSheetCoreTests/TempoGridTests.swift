import Testing

@testable import NeuralSheetCore

@Test func divisionStepsAreFractionsOfABeat() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)
    #expect(grid.secondsPerBeat == 0.5)
    #expect(grid.step == 0.125)
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .bar).step == 2)
    #expect(abs(TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighthTriplet).step - 0.5 / 3) < 1e-12)
    #expect(abs(TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenthTriplet).step - 0.5 / 6) < 1e-12)
    #expect(GridDivision.eighthTriplet.label == "1/8T")
    #expect(GridDivision.bar.label == "1/1")
}

@Test func snapRoundsToTheNearestLineAboutTheOffset() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0.3, division: .quarter)
    #expect(abs(grid.snap(0.5) - 0.3) < 1e-12)
    #expect(abs(grid.snap(0.56) - 0.8) < 1e-12)
    #expect(abs(grid.snapDown(0.79) - 0.3) < 1e-12)
    // Never before the start of the audio.
    #expect(grid.snap(0.0) == 0)
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter).snap(0.24) == 0)
}

@Test func linesAreClassifiedAsBarBeatOrDivision() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighth)
    let lines = grid.lines(from: 0, to: 2)
    #expect(lines.count == 9)
    #expect(lines[0].kind == .bar)
    #expect(lines[1].kind == .division)
    #expect(lines[2].kind == .beat)
    #expect(lines[8].kind == .bar)
    #expect(abs(lines[8].seconds - 2) < 1e-12)

    // Nothing before 0, even when the offset puts a line there.
    let offset = TempoGrid(bpm: 120, offsetSeconds: 0.1, division: .quarter)
    #expect(offset.lines(from: 0, to: 0.2).map(\.seconds) == [0.1])

    // Triplets never land on a beat except at the beat itself.
    let triplet = TempoGrid(bpm: 120, offsetSeconds: 0, division: .eighthTriplet)
    #expect(triplet.lines(from: 0, to: 0.5).map(\.kind) == [.bar, .division, .division, .beat])

    // The ruler asks for beats whatever the snap division is.
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .thirtySecond).lines(from: 0, to: 1, division: .quarter).count == 3)
}

@Test func barBeatCountsFromTheOffsetAndBelowIt() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 1, division: .quarter)
    #expect(grid.barBeat(at: 1) == (1, 1))
    #expect(grid.barBeat(at: 1.5) == (1, 2))
    #expect(grid.barBeat(at: 2.99) == (1, 4))
    #expect(grid.barBeat(at: 3) == (2, 1))
    #expect(grid.barBeat(at: 0.75) == (0, 4))
    #expect(grid.barBeat(at: 0) == (0, 3))
    #expect(grid.barBeatLabel(at: 3.5) == "2.2")
}

@Test func bpmIsClamped() {
    #expect(TempoGrid.clampedBpm(0) == 20)
    #expect(TempoGrid.clampedBpm(.nan) == 120)
    #expect(TempoGrid.clampedBpm(5000) == 999)
    #expect(TempoGrid.clampedBpm(96.5) == 96.5)
}

@Test func exportStartOffsetShiftsTheDownbeatEarlierByWholeBars() {
    // 120 BPM: a bar is 2 s. Bar 1 at 0.5 s is written at the file's bar 2 (0.5 + 1.5 = 2).
    #expect(abs(TempoGrid(bpm: 120, offsetSeconds: 0.5, division: .quarter).exportStartOffsetSeconds - 1.5) < 1e-12)
    // A downbeat already a whole bar in needs no shift.
    #expect(TempoGrid(bpm: 120, offsetSeconds: 2.0, division: .quarter).exportStartOffsetSeconds == 0)
    #expect(TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter).exportStartOffsetSeconds == 0)
}
