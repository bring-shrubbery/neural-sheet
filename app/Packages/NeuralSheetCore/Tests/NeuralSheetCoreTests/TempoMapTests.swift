import Foundation
import Testing

@testable import NeuralSheetCore

/// Bar 1 at 1 s, 4/4 at 120 (2 s bars); bar 3 at 5 s, 3/4 at 60 (3 s bars); bar 5 at 11 s,
/// 6/8 at 90 (three quarters, 2 s bars).
private let map = TempoGrid(segments: [
    GridSegment(startBar: 1, bpm: 120),
    GridSegment(startBar: 3, bpm: 60, timeSignature: TimeSignature(numerator: 3, denominator: 4)),
    GridSegment(startBar: 5, bpm: 90, timeSignature: TimeSignature(numerator: 6, denominator: 8)),
], offsetSeconds: 1, division: .quarter)

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Test func timeSignaturesKnowTheirBarsInQuarters() {
    #expect(TimeSignature.common.quarterBeatsPerBar == 4)
    #expect(TimeSignature(numerator: 3, denominator: 4).quarterBeatsPerBar == 3)
    #expect(TimeSignature(numerator: 6, denominator: 8).quarterBeatsPerBar == 3)
    #expect(TimeSignature(numerator: 7, denominator: 8).quarterBeatsPerBar == 3.5)
    #expect(TimeSignature(numerator: 6, denominator: 8).beatLength == 0.5)
    #expect(TimeSignature(numerator: 6, denominator: 8).isCompound)
    #expect(!TimeSignature(numerator: 3, denominator: 8).isCompound)
    #expect(TimeSignature(numerator: 40, denominator: 5) == TimeSignature(numerator: 32, denominator: 4), "brought into range")
    #expect(TimeSignature(numerator: 7, denominator: 8).label == "7/8")
}

@Test func secondsAndBeatsRoundTripAcrossThreeSegments() {
    #expect(near(map.quarterBeats(atSeconds: 1), 0))
    #expect(near(map.quarterBeats(atSeconds: 5), 8))
    #expect(near(map.quarterBeats(atSeconds: 11), 14))
    #expect(near(map.seconds(atQuarterBeats: 15.5), 12))
    #expect(near(map.quarterBeats(atSeconds: 0), -2), "before bar 1 at the first tempo")

    for seconds in stride(from: 0.0, through: 20, by: 0.37) {
        #expect(near(map.seconds(atQuarterBeats: map.quarterBeats(atSeconds: seconds)), seconds))
    }

    #expect(near(map.barStart(bar: 3), 5))
    #expect(near(map.barStart(bar: 4), 8))
    #expect(near(map.barStart(bar: 6), 13))
    #expect(near(map.barStart(bar: 0), -1))
}

@Test func barBeatAtAndJustBeforeTheBoundaries() {
    #expect(map.barBeat(at: 4.99) == (2, 4))
    #expect(map.barBeat(at: 5) == (3, 1))
    #expect(map.barBeat(at: 7) == (3, 3))
    #expect(map.barBeat(at: 10.99) == (4, 3))
    #expect(map.barBeat(at: 11) == (5, 1))
    #expect(map.barBeat(at: 11 + 1.0 / 3) == (5, 2), "a 6/8 bar counts its eighths")
    #expect(map.barBeat(at: 12.9) == (5, 6))
    #expect(map.barBeatLabel(at: 13) == "6.1")
}

@Test func linesFollowTheMeter() {
    // Bar 3 in 3/4 at 60: three beats a second apart, then bar 4.
    #expect(map.lines(from: 5, to: 8).map(\.kind) == [.bar, .beat, .beat, .bar])
    #expect(map.lines(from: 5, to: 8).map(\.seconds) == [5, 6, 7, 8])

    // Bar 5 in 6/8 on an eighth grid: six beats, then bar 6.
    let eighths = map.lines(from: 11, to: 13, division: .eighth)
    #expect(eighths.map(\.kind) == [.bar, .beat, .beat, .beat, .beat, .beat, .bar])

    // A sixteenth grid stays a sixteenth: twelve to the bar, every other one a beat.
    let sixteenths = map.lines(from: 11, to: 12.99, division: .sixteenth)
    #expect(sixteenths.count == 12)
    #expect(sixteenths.filter { $0.kind == .beat }.count == 5)

    #expect(map.beatLines(from: 11, to: 12.99).count == 6)
    #expect(map.beatLines(from: 5, to: 7.99).count == 3)
}

@Test func aDivisionThatDoesNotFitRestartsAtTheBarLine() {
    let waltz = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 60, timeSignature: TimeSignature(numerator: 3, denominator: 4))],
                          division: .half)
    // Halves at 0 and 2, then the bar line at 3.
    #expect(waltz.lines(from: 0, to: 3).map(\.seconds) == [0, 2, 3])
    #expect(waltz.snap(2.7) == 3, "the bar line is nearer than the last half")
    #expect(waltz.snap(2.4) == 2)
    #expect(waltz.snapDown(2.9) == 2)

    var bars = waltz
    bars.division = .bar
    #expect(bars.lines(from: 0, to: 6).map(\.seconds) == [0, 3, 6])
    #expect(bars.step(atSeconds: 1) == 3)
}

@Test func snapCrossesATempoChange() {
    #expect(near(map.snap(4.9), 5))
    #expect(near(map.snap(5.4), 5), "a beat is a second long after bar 3")
    #expect(near(map.snap(5.6), 6))
    #expect(near(map.snapDown(5.99), 5))
    #expect(near(map.step(atSeconds: 2), 0.5))
    #expect(near(map.step(atSeconds: 6), 1))
}

@Test func theFirstSegmentIsTheOneTempoGrid() {
    var grid = map
    #expect(grid.bpm == 120)
    #expect(grid.timeSignature == .common)
    grid.bpm = 100
    #expect(grid.segments[0].bpm == 100)
    #expect(near(grid.barStart(bar: 3), 1 + 2 * 2.4), "the later segments move with it")
    grid.bpm = 5000
    #expect(grid.bpm == TempoGrid.maxBpm)
}

@Test func addingAndRemovingChangesKeepsTheInvariants() {
    var grid = TempoGrid(bpm: 100)
    let r1 = grid.addChange(atBar: 1)
    #expect(!r1)
    let r2 = grid.addChange(atBar: 0)
    #expect(!r2)
    let r3 = grid.addChange(atBar: 9)
    #expect(r3)
    let r4 = grid.addChange(atBar: 9)
    #expect(!r4, "already a change")
    #expect(grid.segments.map(\.startBar) == [1, 9])
    #expect(grid.segments[1].bpm == 100, "a copy of the covering segment")
    #expect(grid.isChange(atBar: 9))
    #expect(!grid.isChange(atBar: 1))

    grid.setTempo(90, atBar: 12)
    #expect(grid.segments[1].bpm == 90)
    grid.setTimeSignature(TimeSignature(numerator: 3, denominator: 4), atBar: 4)
    #expect(grid.segments[0].timeSignature.numerator == 3)
    let r5 = grid.addChange(atBar: 5)
    #expect(r5)
    #expect(grid.segments.map(\.startBar) == [1, 5, 9])
    #expect(grid.changes.map(\.segment.startBar) == [5, 9])

    let r6 = grid.removeChange(atBar: 1)
    #expect(!r6)
    let r7 = grid.removeChange(atBar: 6)
    #expect(!r7)
    let r8 = grid.removeChange(atBar: 5)
    #expect(r8)
    #expect(grid.segments.map(\.startBar) == [1, 9])
}

@Test func replacingTheMapSanitisesIt() {
    var grid = TempoGrid()
    grid.replaceMap([GridSegment(startBar: 7, bpm: 80), GridSegment(startBar: 3, bpm: 5000), GridSegment(startBar: 7, bpm: 70)],
                    offsetSeconds: -2)
    #expect(grid.segments.map(\.startBar) == [1, 7], "the first moved to bar 1, the last of a bar wins")
    #expect(grid.segments.map(\.bpm) == [TempoGrid.maxBpm, 70])
    #expect(grid.offsetSeconds == 0)

    grid.replaceMap([], offsetSeconds: 1)
    #expect(grid.segments == [GridSegment(startBar: 1, bpm: 120)])
}

@Test func anOldGridPayloadDecodesToOneCommonSegment() throws {
    let old = #"{"bpm": 97, "offsetSeconds": 0.5, "division": "eighth"}"#
    let grid = try JSONDecoder().decode(TempoGrid.self, from: Data(old.utf8))
    #expect(grid == TempoGrid(bpm: 97, offsetSeconds: 0.5, division: .eighth))
    #expect(grid.segments == [GridSegment(startBar: 1, bpm: 97, timeSignature: .common)])

    let encoded = try JSONEncoder().encode(map)
    #expect(try JSONDecoder().decode(TempoGrid.self, from: encoded) == map)
}
