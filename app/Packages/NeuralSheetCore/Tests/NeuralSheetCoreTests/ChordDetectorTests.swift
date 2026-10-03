import Foundation
import Testing

@testable import NeuralSheetCore

/// 120 BPM 4/4 from 0: a bar is two seconds.
private let grid = TempoGrid(bpm: 120)

/// A block chord of `pitches` from `start` for `length` seconds.
private func chord(_ pitches: [Int], at start: Double, length: Double = 2, amplitude: Double = 0.8) -> [NoteEvent] {
    pitches.map { NoteEvent(startTime: start, endTime: start + length, pitch: $0, amplitude: amplitude, program: 0) }
}

private func detectOne(_ pitches: [Int], key: MusicalKey? = nil) -> ChordSymbol? {
    let events = ChordDetector.detect(notes: chord(pitches, at: 0), grid: grid, key: key, duration: 2)
    return events.count == 1 ? events[0].chord : nil
}

@Test func triadsResolveToTheirSymbols() {
    #expect(detectOne([48, 52, 55]) == ChordSymbol(root: 0, quality: .major))
    #expect(detectOne([57, 60, 64]) == ChordSymbol(root: 9, quality: .minor))
    #expect(detectOne([59, 62, 65]) == ChordSymbol(root: 11, quality: .diminished))
    #expect(detectOne([48, 52, 56]) == ChordSymbol(root: 0, quality: .augmented))
    #expect(detectOne([50, 52, 57]) == ChordSymbol(root: 2, quality: .sus2))
    #expect(detectOne([50, 55, 57]) == ChordSymbol(root: 2, quality: .sus4))
}

@Test func seventhsAndSixthsResolveToTheirSymbols() {
    #expect(detectOne([43, 47, 50, 53]) == ChordSymbol(root: 7, quality: .dominantSeventh))
    #expect(detectOne([48, 52, 55, 59]) == ChordSymbol(root: 0, quality: .majorSeventh))
    #expect(detectOne([45, 48, 52, 55]) == ChordSymbol(root: 9, quality: .minorSeventh))
    #expect(detectOne([47, 50, 53, 57]) == ChordSymbol(root: 11, quality: .halfDiminished))
    #expect(detectOne([47, 50, 53, 56]) == ChordSymbol(root: 11, quality: .diminishedSeventh))
    #expect(detectOne([48, 52, 55, 57]) == ChordSymbol(root: 0, quality: .sixth))
    #expect(detectOne([48, 51, 55, 57]) == ChordSymbol(root: 0, quality: .minorSixth))
}

@Test func aQuietPassingNoteDoesNotMakeATriadASeventh() {
    let notes = chord([48, 52, 55], at: 0) + [NoteEvent(startTime: 1, endTime: 1.1, pitch: 71, amplitude: 0.5, program: 0)]
    let events = ChordDetector.detect(notes: notes, grid: grid, key: nil, duration: 2)

    #expect(events.map(\.chord) == [ChordSymbol(root: 0, quality: .major)])
}

@Test func aChordOverItsThirdIsASlashChord() {
    let symbol = detectOne([52, 60, 67])
    #expect(symbol == ChordSymbol(root: 0, quality: .major, bass: 4))
    #expect(symbol?.name(in: nil) == "C/E")
}

@Test func aBarOfCThenGSplitsAtTheHalf() {
    let notes = chord([48, 52, 55], at: 0, length: 1) + chord([43, 47, 50], at: 1, length: 1)
    let events = ChordDetector.detect(notes: notes, grid: grid, key: MusicalKey(tonic: 0, mode: .major), duration: 2)

    #expect(events == [ChordEvent(seconds: 0, chord: ChordSymbol(root: 0, quality: .major)),
                       ChordEvent(seconds: 1, chord: ChordSymbol(root: 7, quality: .major))])
}

@Test func anEmptyBarIsNoChordAndEqualBarsMerge() {
    let notes = chord([48, 52, 55], at: 0) + chord([48, 52, 55], at: 2) + chord([45, 48, 52], at: 6)
    let events = ChordDetector.detect(notes: notes, grid: grid, key: nil, duration: 8)

    #expect(events == [ChordEvent(seconds: 0, chord: ChordSymbol(root: 0, quality: .major)),
                       ChordEvent(seconds: 4, chord: nil),
                       ChordEvent(seconds: 6, chord: ChordSymbol(root: 9, quality: .minor))])
    #expect(events[1].text(in: nil) == "N.C.")
}

@Test func drumsAreIgnoredAndNothingMelodicIsNoList() {
    let drums = [NoteEvent(startTime: 0, endTime: 1, pitch: 36, program: NoteEvent.drumProgram)]
    #expect(ChordDetector.detect(notes: drums, grid: grid, key: nil, duration: 2).isEmpty)
    #expect(ChordDetector.detect(notes: drums + chord([48, 52, 55], at: 0), grid: grid, key: nil, duration: 2)
        .map(\.chord) == [ChordSymbol(root: 0, quality: .major)])
}

@Test func aThreeFourBarSplitsOnABeat() {
    var grid = TempoGrid(bpm: 120)
    grid.timeSignature = TimeSignature(numerator: 3, denominator: 4)
    let notes = chord([48, 52, 55], at: 0, length: 0.5) + chord([43, 47, 50], at: 0.5, length: 1)
    let events = ChordDetector.detect(notes: notes, grid: grid, key: nil, duration: 1.5)

    #expect(events.map(\.seconds) == [0, 0.5])
}

@Test func detectionIsDeterministic() {
    let notes = chord([48, 52, 55], at: 0) + chord([43, 47, 50, 53], at: 2) + chord([45, 48, 52], at: 4, length: 1)
    let first = ChordDetector.detect(notes: notes, grid: grid, key: nil, duration: 6)

    #expect(ChordDetector.detect(notes: notes.reversed(), grid: grid, key: nil, duration: 6) == first)
}

@Test func symbolsAreSpelledFromTheKey() {
    let fMajor = MusicalKey(tonic: 5, mode: .major)
    let bMajor = MusicalKey(tonic: 11, mode: .major)

    #expect(ChordSymbol(root: 10, quality: .major).name(in: fMajor) == "B♭")
    #expect(ChordSymbol(root: 10, quality: .minor).name(in: bMajor) == "A♯m")
    #expect(ChordSymbol(root: 6, quality: .diminished).name(in: nil) == "F♯dim")
    #expect(ChordSymbol(root: 10, quality: .majorSeventh).name(in: nil) == "B♭maj7")
    #expect(ChordSymbol(root: 1, quality: .minor).name(in: nil) == "C♯m")
    #expect(ChordSymbol(root: 11, quality: .halfDiminished).name(in: nil) == "Bm7♭5")
    #expect(ChordSymbol(root: 7, quality: .dominantSeventh, bass: 11).name(in: nil) == "G7/B")
    #expect(ChordSymbol(root: 3, quality: .major, bass: 10).name(in: fMajor) == "E♭/B♭")
    #expect(ChordSymbol(root: 0, quality: .major, bass: 0).name(in: nil) == "C", "a bass on the root writes no slash")
    #expect(ChordQuality.allCases.map(\.suffix) == ["", "m", "dim", "aug", "sus2", "sus4", "6", "m6", "7", "maj7", "m7", "m7♭5", "dim7"])
}

@Test func theListSortsAndFindsTheChordAtATime() {
    let list = [ChordEvent(seconds: 2, chord: nil), ChordEvent(seconds: -1, chord: ChordSymbol(root: 0, quality: .major))].sortedChords()

    #expect(list.map(\.seconds) == [0, 2])
    #expect(list.chordIndex(at: 1) == 0)
    #expect(list.chordIndex(at: 3) == 1)
    #expect([ChordEvent(seconds: 1, chord: nil)].chordIndex(at: 0.5) == nil)
}
