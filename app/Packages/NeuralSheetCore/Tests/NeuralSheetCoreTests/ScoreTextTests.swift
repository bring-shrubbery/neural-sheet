import Foundation
import Testing

@testable import NeuralSheetCore

// Markers and lyrics in the score and the exports (markers and lyrics design §2, §3): the bar a
// marker lands on, the lyric line, the MusicXML elements and the MIDI meta events.

/// 4/4 at 120: a bar every 2 s.
private let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)

/// Eight quarter notes over two bars, the first four sung "Twin-kle twin-kle".
private let sung: [NoteEvent] = {
    let words = LyricSplitter.syllables(from: "Twin-kle twin-kle_")
    return (0..<8).map { index in
        NoteEvent(startTime: Double(index) * 0.5, endTime: Double(index + 1) * 0.5, pitch: 60 + index, program: 0,
                  lyric: index < words.count ? words[index] : nil)
    }
}()

private func measures(_ markers: [Marker], notes: [NoteEvent] = sung) -> [ScoreRehearsal] {
    ScoreDocument.build(notes: notes, grid: grid, key: nil, markers: markers).rehearsalMarks
}

// MARK: - Rehearsal marks

@Test func aMarkerLandsOnTheNearestBarLine() {
    #expect(measures([Marker(seconds: 2, name: "Verse")]) == [ScoreRehearsal(measure: 1, text: "Verse")])
    #expect(measures([Marker(seconds: 1.95, name: "Verse")]) == [ScoreRehearsal(measure: 1, text: "Verse")])
    #expect(measures([Marker(seconds: 0.9, name: "Intro")]) == [ScoreRehearsal(measure: 0, text: "Intro")])
}

@Test func markersPastTheEndOrUnnamedAreLeftOutAndSharersJoin() {
    #expect(measures([Marker(seconds: 3.9, name: "Outro")]).isEmpty)
    #expect(measures([Marker(seconds: 0, name: "  ")]).isEmpty)
    #expect(measures([Marker(seconds: 0.1, name: "A"), Marker(seconds: 0, name: "B")]) == [ScoreRehearsal(measure: 0, text: "B / A")])
}

// MARK: - Lyrics in the score

@Test func theScoreCarriesEachSyllableOnItsOnsetOnly() throws {
    let tied = [NoteEvent(startTime: 1.5, endTime: 2.5, pitch: 60, program: 0, lyric: Lyric(text: "la"))]
    let document = ScoreDocument.build(notes: tied, grid: grid, key: nil)
    let notes = document.parts[0].staves[0].measures.flatMap(\.pieces).flatMap(\.notes)

    #expect(notes.count == 2)
    #expect(notes[0].lyric?.text == "la")
    #expect(notes[1].lyric == nil)
    #expect(document.parts[0].hasLyrics)
}

@Test func aPartWithWordsGetsALyricLine() {
    let plain = sung.map { note -> NoteEvent in
        var note = note
        note.lyric = nil
        return note
    }
    let withWords = ScoreDocument.build(notes: sung, grid: grid, key: nil)
    let without = ScoreDocument.build(notes: plain, grid: grid, key: nil)
    let sp: CGFloat = 8

    let height = ScoreSystemLayout.systemHeight(for: withWords, arrangement: ScoreArrangement(), sp: sp)
    let plainHeight = ScoreSystemLayout.systemHeight(for: without, arrangement: ScoreArrangement(), sp: sp)
    #expect(height == plainHeight + ScoreSystemLayout.lyricLine * sp)

    let layout = ScoreSystemLayout(document: withWords, arrangement: ScoreArrangement(), width: 2000, sp: sp)
    #expect(layout.systems[0].rows[0].lyricsBelow)
}

@Test func aScoreWithRehearsalMarksGivesEverySystemRoomForThem() {
    let sp: CGFloat = 8
    let plain = ScoreDocument.build(notes: sung, grid: grid, key: nil)
    let marked = ScoreDocument.build(notes: sung, grid: grid, key: nil, markers: [Marker(seconds: 0, name: "Intro")])
    let plainLayout = ScoreSystemLayout(document: plain, arrangement: ScoreArrangement(), width: 2000, sp: sp)
    let markedLayout = ScoreSystemLayout(document: marked, arrangement: ScoreArrangement(), width: 2000, sp: sp)

    #expect(markedLayout.systems[0].frame.height == plainLayout.systems[0].frame.height + ScoreSystemLayout.rehearsalRoom * sp)
    #expect(markedLayout.systems[0].rows[0].bottomLineY == plainLayout.systems[0].rows[0].bottomLineY + ScoreSystemLayout.rehearsalRoom * sp)
}

// MARK: - MusicXML

@Test func musicXMLWritesTheRehearsalMarkInItsMeasureOnTheFirstPart() throws {
    let twoParts = sung + [NoteEvent(startTime: 0, endTime: 4, pitch: 40, program: 33)]
    let xml = try #require(String(data: MusicXMLWriter.data(notes: twoParts, grid: grid, key: nil,
                                                            markers: [Marker(seconds: 2, name: "Verse & Co")]),
                                  encoding: .utf8))
    let mark = "<direction placement=\"above\"><direction-type><rehearsal>Verse &amp; Co</rehearsal></direction-type></direction>"

    #expect(xml.components(separatedBy: "<rehearsal>").count - 1 == 1)
    let measure2 = try #require(xml.range(of: "<measure number=\"2\">"))
    let rehearsal = try #require(xml.range(of: mark))
    let firstNote = try #require(xml.range(of: "<note>", range: measure2.upperBound..<xml.endIndex))
    #expect(rehearsal.lowerBound > measure2.upperBound && rehearsal.lowerBound < firstNote.lowerBound)
    #expect(try XMLDocument(xmlString: xml, options: []).rootElement() != nil)
}

@Test func musicXMLWritesTheLyricsWithSyllabicAndExtend() throws {
    let xml = try #require(String(data: MusicXMLWriter.data(notes: sung, grid: grid, key: nil), encoding: .utf8))

    #expect(xml.contains("<lyric number=\"1\"><syllabic>begin</syllabic><text>Twin</text></lyric></note>"))
    #expect(xml.contains("<lyric number=\"1\"><syllabic>end</syllabic><text>kle</text></lyric>"))
    #expect(xml.contains("<lyric number=\"1\"><syllabic>end</syllabic><text>kle</text><extend type=\"start\"/></lyric>"))
    #expect(xml.components(separatedBy: "<lyric ").count - 1 == 4)

    let document = try XMLDocument(xmlString: xml, options: [])
    #expect(try document.nodes(forXPath: "//measure[@number='1']/note/lyric").count == 4)
}

// MARK: - MIDI

private func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
    bytes.indices.contains { bytes[$0...].starts(with: needle) }
}

@Test func midiWritesAMarkerEventInTheConductorTrack() {
    let data = [UInt8](MidiFileWriter.data(notes: sung, grid: grid, mode: .reuseChannels,
                                           markers: [Marker(seconds: 2, name: "Verse")]))
    let conductor = Array(data[22..<(22 + Int(data[21]))])

    // Tempo and meter at 0, then the marker 4 quarters (3840 ticks = 0x9E 0x00) in.
    #expect(contains(conductor, [0x9E, 0x00, 0xFF, 0x06, 0x05] + Array("Verse".utf8)))
}

@Test func midiWritesALyricEventAheadOfEachStrike() {
    let data = [UInt8](MidiFileWriter.data(notes: sung, grid: grid, mode: .reuseChannels))

    // "Twin-" at tick 0, before the first note on.
    #expect(contains(data, [0x00, 0xFF, 0x05, 0x05] + Array("Twin-".utf8) + [0x00, 0x90, 0x3C]))
    #expect(contains(data, [0xFF, 0x05, 0x03] + Array("kle".utf8)))
}

@Test func aFileWithoutWordsIsUnchanged() {
    let plain = sung.map { note -> NoteEvent in
        var note = note
        note.lyric = nil
        return note
    }

    let bytes = [UInt8](MidiFileWriter.data(notes: plain, grid: grid, mode: .reuseChannels, markers: []))

    #expect(bytes == [UInt8](MidiFileWriter.data(notes: plain, grid: grid, mode: .reuseChannels)))
    #expect(!contains(bytes, [0xFF, 0x05]) && !contains(bytes, [0xFF, 0x06]))
}
