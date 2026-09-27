import Foundation
import Testing

@testable import NeuralSheetCore

private let guitar = [40, 45, 50, 55, 59, 64]
private let openG = [67, 50, 55, 59, 62]

@Test func aNoteTakesTheLowestFretThatFits() {
    let placements = TabFingering.place(pitches: [64], tuning: guitar, frets: 24, manual: [nil])
    #expect(placements == [.init(string: 5, fret: 0, isPlayable: true)], "open high E, not the 5th fret of B")

    let g3 = TabFingering.place(pitches: [55], tuning: guitar, frets: 24, manual: [nil])
    #expect(g3 == [.init(string: 3, fret: 0, isPlayable: true)])
}

@Test func anOpenGBanjoChordLandsOnOpenStrings() {
    let placements = TabFingering.place(pitches: [50, 55, 59, 62, 67], tuning: openG, frets: 22, manual: [nil, nil, nil, nil, nil])
    #expect(placements.map(\.string) == [1, 2, 3, 4, 0])
    #expect(placements.allSatisfy { $0.fret == 0 && $0.isPlayable })
}

@Test func aChordFillsDistinctStrings() {
    // E major barre shapes share pitches with open strings; the strings must not double up.
    let placements = TabFingering.place(pitches: [40, 47, 52, 56, 59, 64], tuning: guitar, frets: 24, manual: Array(repeating: nil, count: 6))
    #expect(Set(placements.map(\.string)).count == 6)
    #expect(placements.allSatisfy { $0.isPlayable })
}

@Test func impossibleNotesArePlacedAndMarked() {
    let low = TabFingering.place(pitches: [38], tuning: guitar, frets: 24, manual: [nil])
    #expect(low == [.init(string: 0, fret: -2, isPlayable: false)], "below the lowest open string: the lowest string, a negative fret")

    let high = TabFingering.place(pitches: [100], tuning: guitar, frets: 24, manual: [nil])
    #expect(high == [.init(string: 5, fret: 36, isPlayable: false)])

    // Seven notes on six strings: the surplus goes to the last string, unplayable.
    let seven = TabFingering.place(pitches: [40, 45, 50, 55, 59, 64, 65], tuning: guitar, frets: 24, manual: Array(repeating: nil, count: 7))
    #expect(seven.filter { !$0.isPlayable }.count == 1)
    #expect(seven.last?.string == 5)
}

@Test func aManualChoiceWinsAndMayBeImpossible() {
    let onA = TabFingering.place(pitches: [64], tuning: guitar, frets: 24, manual: [1])
    #expect(onA == [.init(string: 1, fret: 19, isPlayable: true)])

    let onLowE = TabFingering.place(pitches: [38], tuning: guitar, frets: 24, manual: [2])
    #expect(onLowE == [.init(string: 2, fret: -12, isPlayable: false)])

    // A manual choice takes its string before the automatic notes pick theirs.
    let chord = TabFingering.place(pitches: [55, 59], tuning: guitar, frets: 24, manual: [nil, 3])
    #expect(chord[1] == .init(string: 3, fret: 4, isPlayable: true))
    #expect(chord[0].string == 2, "G3 moves to the D string, fret 5, since the G string is taken")
    #expect(chord[0].fret == 5)

    let outOfRange = TabFingering.place(pitches: [55], tuning: guitar, frets: 24, manual: [9])
    #expect(outOfRange[0].string == 5, "a string the template does not have is clamped to the top one")
}
