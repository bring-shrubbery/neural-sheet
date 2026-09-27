import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Pieces

@Test func pitchesAreSpelledInSharpsOrFlats() {
    #expect(MusicXMLWriter.spelling(midi: 60, preferFlats: false) == .init(step: "C", alter: 0, octave: 4))
    #expect(MusicXMLWriter.spelling(midi: 61, preferFlats: false) == .init(step: "C", alter: 1, octave: 4))
    #expect(MusicXMLWriter.spelling(midi: 61, preferFlats: true) == .init(step: "D", alter: -1, octave: 4))
    #expect(MusicXMLWriter.spelling(midi: 59, preferFlats: false) == .init(step: "B", alter: 0, octave: 3))
    #expect(MusicXMLWriter.spelling(midi: 21, preferFlats: false) == .init(step: "A", alter: 0, octave: 0))
}

@Test func printableDurationsSplitGreedily() {
    #expect(MusicXMLWriter.printableDurations(96).map(\.type) == ["whole"])
    #expect(MusicXMLWriter.printableDurations(30).map(\.type) == ["quarter", "16th"])
    #expect(MusicXMLWriter.printableDurations(18) == [.init(units: 18, type: "eighth", dots: 1)])
    #expect(MusicXMLWriter.printableDurations(54).map(\.units) == [48, 6])
    #expect(MusicXMLWriter.printableDurations(2).map(\.units) == [3], "under a 32nd rounds up to one")
    #expect(MusicXMLWriter.printableDurations(0).isEmpty)
}

@Test func notesQuantizeToTheGridDivision() {
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)
    let notes = [NoteEvent(startTime: 0.26, endTime: 0.74, pitch: 60, program: 0)]
    let units = MusicXMLWriter.unitNotes(notes, grid: grid, quantum: MusicXMLWriter.quantum(for: .sixteenth))

    #expect(units == [.init(start: 12, end: 36, pitch: 60)])

    // A sliver is one division long; a triplet division straightens.
    let sliver = MusicXMLWriter.unitNotes([NoteEvent(startTime: 1.0, endTime: 1.01, pitch: 60, program: 0)], grid: grid, quantum: 6)
    #expect(sliver == [.init(start: 48, end: 54, pitch: 60)])
    #expect(MusicXMLWriter.quantum(for: .eighthTriplet) == 12)
    #expect(MusicXMLWriter.quantum(for: .bar) == 96)
}

@Test func segmentsChangeAtEveryOnsetOffsetAndBarLine() {
    let notes = [
        MusicXMLWriter.UnitNote(start: 0, end: 24, pitch: 60),
        MusicXMLWriter.UnitNote(start: 12, end: 36, pitch: 64),
    ]
    let segments = MusicXMLWriter.segments(notes, from: 0, to: 48)

    #expect(segments.map { [$0.start, $0.end] } == [[0, 12], [12, 24], [24, 36], [36, 48]])
    #expect(segments[0].notes.map(\.pitch) == [60])
    #expect(segments[1].notes.map(\.pitch) == [60, 64])
    #expect(segments[2].notes.map(\.pitch) == [64])
    #expect(segments[3].isRest)

    // A note across a bar line is cut there.
    let across = MusicXMLWriter.segments([.init(start: 72, end: 120, pitch: 60)], from: 0, to: 192)
    #expect(across.map { [$0.start, $0.end] } == [[0, 72], [72, 96], [96, 120], [120, 192]])
}

// MARK: - Documents

private func document(_ notes: [NoteEvent], grid: TempoGrid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth),
                      fifths: Int = 0) throws -> XMLDocument {
    try XMLDocument(data: MusicXMLWriter.data(notes: notes, grid: grid, fifths: fifths, title: "Take & <Test>"), options: [])
}

private func count(_ xpath: String, in document: XMLDocument) throws -> Int {
    try document.nodes(forXPath: xpath).count
}

@Test func aScaleOfQuartersIsTwoBarsOfFour() throws {
    let scale = [60, 62, 64, 65, 67, 69, 71, 72].enumerated().map { index, pitch in
        NoteEvent(startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 0.5, pitch: pitch, program: 0)
    }
    let score = try document(scale)

    #expect(try count("//part", in: score) == 1)
    #expect(try count("//measure", in: score) == 2)
    #expect(try count("//note", in: score) == 8)
    #expect(try count("//note/rest", in: score) == 0)
    #expect(try count("//note[type='quarter']", in: score) == 8)
    #expect(try count("//note/tie", in: score) == 0)
    #expect(try count("//attributes/clef[sign='G']", in: score) == 1)
    #expect(try count("//direction/sound[@tempo='120']", in: score) == 1)
    #expect(try count("//part-list/score-part/part-name[text()='Piano']", in: score) == 1)
    #expect(try score.nodes(forXPath: "//work-title").first?.stringValue == "Take & <Test>", "the title is escaped and parses back")
    #expect(try count("//measure[1]/attributes/divisions[text()='24']", in: score) == 1)
}

@Test func aNoteAcrossTheBarLineIsTied() throws {
    let score = try document([NoteEvent(startTime: 1.5, endTime: 2.5, pitch: 67, program: 0)])

    #expect(try count("//measure", in: score) == 2)
    #expect(try count("//note[pitch]", in: score) == 2)
    #expect(try count("//note/tie[@type='start']", in: score) == 1)
    #expect(try count("//note/tie[@type='stop']", in: score) == 1)
    #expect(try count("//note/notations/tied[@type='start']", in: score) == 1)
    // A dotted-half rest then the note in bar one; the note then a dotted-half rest in bar two.
    #expect(try count("//measure[1]/note/rest", in: score) == 1)
    #expect(try count("//measure[1]/note[rest]/type[text()='half']", in: score) == 1)
    #expect(try count("//measure[1]/note[rest]/dot", in: score) == 1)
}

@Test func notesAtOneOnsetAreAChord() throws {
    let score = try document([
        NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0),
        NoteEvent(startTime: 0, endTime: 1, pitch: 64, program: 0),
        NoteEvent(startTime: 0, endTime: 1, pitch: 67, program: 0),
    ])

    // Three notes for the chord, then a half rest to the bar line.
    #expect(try count("//note[pitch]", in: score) == 3)
    #expect(try count("//note/chord", in: score) == 2)
    #expect(try count("//note[pitch][type='half']", in: score) == 3)
    #expect(try count("//note[rest][type='half']", in: score) == 1)
    // Ascending pitch inside the chord.
    #expect(try score.nodes(forXPath: "//note/pitch/step").map(\.stringValue) == ["C", "E", "G"])
}

@Test func aGapIsAWholeMeasureRest() throws {
    let score = try document([
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 0),
        NoteEvent(startTime: 4, endTime: 4.5, pitch: 60, program: 0),
    ])

    #expect(try count("//measure", in: score) == 3)
    #expect(try count("//measure[2]/note/rest[@measure='yes']", in: score) == 1)
    #expect(try count("//measure[2]/note", in: score) == 1)
}

@Test func drumsGetAPercussionStaff() throws {
    let score = try document([
        NoteEvent(startTime: 0, endTime: 0.1, pitch: 36, program: NoteEvent.drumProgram),
        NoteEvent(startTime: 0.5, endTime: 0.6, pitch: 42, program: NoteEvent.drumProgram),
    ])

    #expect(try count("//attributes/clef[sign='percussion']", in: score) == 1)
    #expect(try count("//note/unpitched", in: score) == 2)
    #expect(try count("//note/pitch", in: score) == 0)
    #expect(try count("//note/notehead[text()='x']", in: score) == 1)
    #expect(try count("//midi-instrument/midi-channel[text()='10']", in: score) == 1)
    #expect(try count("//part-list/score-part/part-name[text()='Drums']", in: score) == 1)
}

@Test func aPartOnBothSidesOfMiddleCGetsTwoStaves() throws {
    var notes: [NoteEvent] = []
    for index in 0..<8 {
        notes.append(NoteEvent(startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 0.5, pitch: 72, program: 0))
        notes.append(NoteEvent(startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 0.5, pitch: 48, program: 0))
    }
    let score = try document(notes)

    #expect(try count("//attributes/staves[text()='2']", in: score) == 1)
    #expect(try count("//attributes/clef", in: score) == 2)
    #expect(try count("//measure/backup", in: score) == 2, "one backup per measure between the staves")
    #expect(try count("//note[staff='1']", in: score) == 8)
    #expect(try count("//note[staff='2']", in: score) == 8)
    #expect(try count("//note[staff='2'][voice='2']", in: score) == 8)
    #expect(try count("//note/chord", in: score) == 0, "the two hands are not one chord")

    // A low part alone reads in the bass clef.
    let low = try document([NoteEvent(startTime: 0, endTime: 1, pitch: 40, program: 33)])
    #expect(try count("//attributes/clef[sign='F']", in: low) == 1)
}

@Test func partsFollowTheSidebarOrderWithTheKeyAndTheDownbeat() throws {
    let grid = TempoGrid(bpm: 100, offsetSeconds: 1.0, division: .eighth)
    let score = try document([
        NoteEvent(startTime: 1.0, endTime: 1.6, pitch: 61, program: 40),
        NoteEvent(startTime: 0.4, endTime: 1.0, pitch: 36, program: 0),
        NoteEvent(startTime: 1.0, endTime: 1.3, pitch: 38, program: NoteEvent.drumProgram),
    ], grid: grid, fifths: -2)

    #expect(try score.nodes(forXPath: "//part-list/score-part/part-name").map(\.stringValue) == ["Piano", "Violin", "Drums"])
    #expect(try count("//key/fifths[text()='-2']", in: score) == 3)
    #expect(try count("//note/pitch[step='D'][alter='-1']", in: score) == 1, "a flat key spells in flats")
    #expect(try count("//direction/sound[@tempo='100']", in: score) == 1)
    // The piano note is a beat before the downbeat: the score starts a bar early, and every part
    // spans the same two measures.
    #expect(try count("//part[1]/measure", in: score) == 2)
    #expect(try count("//part[2]/measure", in: score) == 2)
    #expect(try count("//part[1]/measure[1]/note[pitch]", in: score) == 1)
    #expect(try count("//part[2]/measure[1]/note[pitch]", in: score) == 0)
}

@Test func anEmptyTranscriptionIsOneRestingMeasure() throws {
    let score = try document([])

    #expect(try count("//part", in: score) == 1)
    #expect(try count("//measure", in: score) == 1)
    #expect(try count("//note/rest[@measure='yes']", in: score) == 1)
}

@Test func musicXMLFileNamesFollowTheMidiRule() {
    #expect(MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: "song") == "song_NNTranscription.musicxml")
    #expect(MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: nil) == "NNTranscription.musicxml")
    #expect(MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: "") == "NNTranscription.musicxml")
}

// MARK: - The arrangement

@Test func theExportFollowsTheArrangement() throws {
    var arrangement = ScoreArrangement()
    var trumpet = PartDisplay()
    trumpet.transposition = 2
    trumpet.clef = .treble
    arrangement.parts[56] = trumpet
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.transposition = 12
    guitar.clef = .treble8vb
    let template = TabTemplate.template(id: "guitar")!
    guitar.tab = template.setup(preset: template.presets[0])
    arrangement.parts[24] = guitar
    var hidden = PartDisplay()
    hidden.isHidden = true
    arrangement.parts[0] = hidden
    arrangement.sheet.title = "Reel"
    arrangement.sheet.subtitle = "Set 2"
    arrangement.sheet.composer = "Trad."
    arrangement.sheet.arranger = "A."
    arrangement.sheet.copyright = "© 2026"

    let notes = [
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 56),
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 64, program: 24),
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 0),
    ]
    let data = MusicXMLWriter.data(notes: notes, ids: nil, grid: TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth),
                                   key: MusicalKey(tonic: 0, mode: .major), title: nil, arrangement: arrangement, takeName: "take")
    let score = try XMLDocument(data: data, options: [])
    let guitarName = Instruments.info(forProgram: 24).name
    let trumpetName = Instruments.info(forProgram: 56).name

    #expect(try score.nodes(forXPath: "//part-list/score-part/part-name").map(\.stringValue) == [guitarName, "\(guitarName) (TAB)", trumpetName],
            "the piano is hidden; the tab is a part of its own")
    #expect(try score.nodes(forXPath: "//part-list/score-part/@id").map(\.stringValue) == ["P1", "P1T", "P2"])
    #expect(try score.nodes(forXPath: "//part/@id").map(\.stringValue) == ["P1", "P1T", "P2"])
    #expect(try score.nodes(forXPath: "//work-title").first?.stringValue == "Reel")
    #expect(try score.nodes(forXPath: "//identification/creator[@type='composer']").first?.stringValue == "Trad.")
    #expect(try score.nodes(forXPath: "//identification/creator[@type='arranger']").first?.stringValue == "A.")
    #expect(try score.nodes(forXPath: "//identification/rights").first?.stringValue == "© 2026")
    #expect(try score.nodes(forXPath: "//credit/credit-words").first?.stringValue == "Set 2")
    #expect(try count("//direction/sound[@tempo='120']", in: score) == 1, "the tempo is on the first part only")

    // The trumpet: written a tone up, D major, with the transpose element MusicXML expects (sounding = written + chromatic).
    #expect(try score.nodes(forXPath: "//part[3]/measure[1]/attributes/key/fifths").first?.stringValue == "2")
    #expect(try score.nodes(forXPath: "//part[3]/measure[1]/attributes/transpose/chromatic").first?.stringValue == "-2")
    #expect(try count("//part[3]/measure[1]/attributes/transpose/octave-change", in: score) == 0)
    #expect(try score.nodes(forXPath: "//part[3]//note/pitch/step").first?.stringValue == "D")

    // The guitar's notation: treble 8vb, written an octave up; its tab: six lines, the tuning, string and fret.
    #expect(try score.nodes(forXPath: "//part[1]/measure[1]/attributes/clef/sign").first?.stringValue == "G")
    #expect(try score.nodes(forXPath: "//part[1]/measure[1]/attributes/clef/clef-octave-change").first?.stringValue == "-1")
    #expect(try score.nodes(forXPath: "//part[1]/measure[1]/attributes/transpose/chromatic").first?.stringValue == "0")
    #expect(try score.nodes(forXPath: "//part[1]/measure[1]/attributes/transpose/octave-change").first?.stringValue == "-1")
    #expect(try score.nodes(forXPath: "//part[1]//note/pitch/octave").first?.stringValue == "5")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/clef/sign").first?.stringValue == "TAB")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-lines").first?.stringValue == "6")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-tuning").count == 6)
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-tuning[@line='1']/tuning-step").first?.stringValue == "E")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-tuning[@line='1']/tuning-octave").first?.stringValue == "2")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-tuning[@line='6']/tuning-octave").first?.stringValue == "4")
    #expect(try score.nodes(forXPath: "//part[2]//note/pitch/octave").first?.stringValue == "4", "the tab carries the sounding pitch")
    #expect(try score.nodes(forXPath: "//part[2]//note/notations/technical/string").first?.stringValue == "1", "the high E is string 1 in MusicXML's numbering")
    #expect(try score.nodes(forXPath: "//part[2]//note/notations/technical/fret").first?.stringValue == "0")
    #expect(try count("//part[2]//note[rest]", in: score) == 1, "the tab rests where the notation rests")
}

@Test func transpositionsBecomeChromaticAndOctaveChange() {
    #expect(MusicXMLWriter.transposeXML(2) == "<transpose><chromatic>-2</chromatic></transpose>")
    #expect(MusicXMLWriter.transposeXML(12) == "<transpose><chromatic>0</chromatic><octave-change>-1</octave-change></transpose>")
    #expect(MusicXMLWriter.transposeXML(14) == "<transpose><chromatic>-2</chromatic><octave-change>-1</octave-change></transpose>")
    #expect(MusicXMLWriter.transposeXML(-12) == "<transpose><chromatic>0</chromatic><octave-change>1</octave-change></transpose>")
    #expect(MusicXMLWriter.transposeXML(0).isEmpty)
}
