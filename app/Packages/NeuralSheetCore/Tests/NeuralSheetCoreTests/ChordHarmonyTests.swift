import Foundation
import Testing

@testable import NeuralSheetCore

/// Two bars of whole-note Cs at 120 BPM 4/4: a bar is two seconds, a quarter 24 units.
private let notes = [NoteEvent(startTime: 0, endTime: 4, pitch: 60, program: 0)]
private let grid = TempoGrid(bpm: 120)

private let chords = [
    ChordEvent(seconds: 0, chord: ChordSymbol(root: 9, quality: .minorSeventh)),
    ChordEvent(seconds: 2, chord: ChordSymbol(root: 10, quality: .major, bass: 2)),
    ChordEvent(seconds: 3, chord: nil),
]

@Test func theScorePlacesChordsOnItsMeasures() {
    let document = ScoreDocument.build(notes: notes, grid: grid, key: MusicalKey(tonic: 5, mode: .major), chords: chords)

    #expect(document.chords.map(\.measure) == [0, 1, 1])
    #expect(document.chords.map(\.units) == [0, 0, 48])
    #expect(document.chords.map(\.text) == ["Am7", "B♭/D", "N.C."])
    #expect(document.chords.map(\.index) == [0, 1, 2])
    #expect(document.chords.inMeasure(1).map(\.text) == ["B♭/D", "N.C."])
    #expect(document.chords.inMeasure(5).isEmpty)
}

@Test func aChordSoundingBeforeTheFirstMeasureIsWrittenOnIt() {
    let late = [NoteEvent(startTime: 4, endTime: 6, pitch: 60, program: 0)]
    let document = ScoreDocument.build(notes: late, grid: grid, key: nil, chords: chords)

    #expect(document.firstBar == 2)
    #expect(document.chords.map(\.text) == ["N.C."])
    #expect(document.chords.first?.units == 0)
    #expect(document.chords.first?.index == 2)
}

@Test func musicXMLWritesHarmonyWithKindBassAndOffset() throws {
    let xml = try #require(String(data: MusicXMLWriter.data(notes: notes, grid: grid, key: MusicalKey(tonic: 5, mode: .major),
                                                            chords: chords), encoding: .utf8))

    #expect(xml.contains("<harmony print-frame=\"no\"><root><root-step>A</root-step></root><kind text=\"m7\">minor-seventh</kind></harmony>"))
    #expect(xml.contains("<root><root-step>B</root-step><root-alter>-1</root-alter></root><kind>major</kind><bass><bass-step>D</bass-step></bass></harmony>"))
    #expect(xml.contains("<kind text=\"N.C.\">none</kind><offset>48</offset></harmony>"))

    // Each harmony sits in the measure before its note: measure 2 opens with B♭/D.
    let measure2 = try #require(xml.range(of: "<measure number=\"2\">"))
    let firstNote = try #require(xml.range(of: "<note>", range: measure2.upperBound..<xml.endIndex))
    let harmony = try #require(xml.range(of: "<harmony", range: measure2.upperBound..<xml.endIndex))
    #expect(harmony.lowerBound < firstNote.lowerBound)
}

@Test func harmonyGoesOnlyOnTheFirstPart() throws {
    let twoParts = notes + [NoteEvent(startTime: 0, endTime: 4, pitch: 40, program: 33)]
    let xml = try #require(String(data: MusicXMLWriter.data(notes: twoParts, grid: grid, key: nil, chords: chords), encoding: .utf8))

    #expect(xml.components(separatedBy: "<harmony").count - 1 == 3)
    let secondPart = try #require(xml.range(of: "<part id=\"P2\">"))
    #expect(xml.range(of: "<harmony", range: secondPart.upperBound..<xml.endIndex) == nil)
}

@Test func harmonyKindsCoverEveryQuality() {
    for quality in ChordQuality.allCases {
        let xml = MusicXMLWriter.harmonyXML(ScoreChord(measure: 0, units: 0, text: "", chord: ChordSymbol(root: 0, quality: quality),
                                                       flats: false), offset: 0)
        #expect(xml.contains(">\(quality.musicXMLKind)</kind>"))
    }

    let halfDiminished = MusicXMLWriter.harmonyXML(ScoreChord(measure: 0, units: 0, text: "",
                                                              chord: ChordSymbol(root: 11, quality: .halfDiminished), flats: false),
                                                   offset: 12)
    #expect(halfDiminished.contains("<kind text=\"m7b5\">half-diminished</kind>"))
    #expect(halfDiminished.contains("<offset>12</offset>"))
}
