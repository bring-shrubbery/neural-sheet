import Foundation
import Testing

@testable import NeuralSheetCore

// The score, MusicXML and MIDI over a tempo map (tempo map design §3).

private let waltz = TimeSignature(numerator: 3, denominator: 4)

/// 4/4 at 120 for bars 1–4, then 3/4 at 90 from bar 5 (8 s in).
private let changing = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120),
                                            GridSegment(startBar: 5, bpm: 90, timeSignature: waltz)],
                                 offsetSeconds: 0, division: .sixteenth)

private func quarters(_ count: Int, from start: Double = 0, every step: Double = 0.5) -> [NoteEvent] {
    (0..<count).map { NoteEvent(startTime: start + Double($0) * step, endTime: start + Double($0 + 1) * step, pitch: 60 + $0 % 12, program: 0) }
}

private func xml(_ notes: [NoteEvent], grid: TempoGrid) throws -> XMLDocument {
    try XMLDocument(data: MusicXMLWriter.data(notes: notes, grid: grid), options: [])
}

private func count(_ xpath: String, in document: XMLDocument) throws -> Int {
    try document.nodes(forXPath: xpath).count
}

@Test func aWaltzHasBarsOfThree() throws {
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120, timeSignature: waltz)], division: .sixteenth)
    let score = ScoreDocument.build(notes: quarters(6), grid: grid, key: nil)

    #expect(score.measureCount == 2)
    #expect(score.bars.map(\.lengthUnits) == [72, 72])
    #expect(score.bars.map(\.startUnits) == [0, 72])
    #expect(score.parts[0].staves[0].measures[0].lengthUnits == 72)
    #expect(score.parts[0].staves[0].measures[0].timeSignature == waltz)
    #expect(score.parts[0].staves[0].measures[1].timeSignature == nil, "shown only where it changes")
    #expect(score.parts[0].staves[0].measures.allSatisfy { $0.pieces.count == 3 }, "three quarters a bar")

    let document = try xml(quarters(6), grid: grid)
    #expect(try count("//measure", in: document) == 2)
    #expect(try count("//measure[1]/attributes/time[beats='3'][beat-type='4']", in: document) == 1)
    #expect(try count("//time", in: document) == 1)
}

@Test func anEmptyBarInThreeIsAWholeMeasureRestOfThree() throws {
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120, timeSignature: waltz)], division: .sixteenth)
    let document = try xml([NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 0),
                            NoteEvent(startTime: 3, endTime: 4.5, pitch: 60, program: 0)], grid: grid)

    #expect(try count("//measure[2]/note/rest[@measure='yes']", in: document) == 1)
    #expect(try document.nodes(forXPath: "//measure[2]/note/duration").first?.stringValue == "72")
}

@Test func aChangeAtBarFiveWritesASecondTimeAndTempo() throws {
    // Sixteen quarters at 120 fill bars 1–4; three more at 90 (2/3 s apart) fill bar 5.
    let notes = quarters(16) + quarters(3, from: 8, every: 2.0 / 3)
    let score = ScoreDocument.build(notes: notes, grid: changing, key: nil)

    #expect(score.bars.map(\.lengthUnits) == [96, 96, 96, 96, 72])
    #expect(score.bars.map(\.showsTempo) == [true, false, false, false, true])
    #expect(score.parts[0].staves[0].measures[4].pieces.map(\.units) == [24, 24, 24], "the notes land in bar 5's beats")
    #expect(score.parts[0].staves[0].measures[4].tempo == 90)

    let document = try xml(notes, grid: changing)
    #expect(try count("//time", in: document) == 2)
    #expect(try count("//measure[5]/attributes/time[beats='3']", in: document) == 1)
    #expect(try count("//direction/sound[@tempo='120']", in: document) == 1)
    #expect(try count("//measure[5]/direction/sound[@tempo='90']", in: document) == 1)
    #expect(try count("//measure[5]/direction//per-minute[text()='90']", in: document) == 1)
}

@Test func aCompoundMeterCountsItsTempoInDottedQuarters() throws {
    let jig = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120, timeSignature: TimeSignature(numerator: 6, denominator: 8))])
    let document = try xml(quarters(3), grid: jig)

    #expect(try count("//metronome/beat-unit-dot", in: document) == 1)
    #expect(try count("//metronome/per-minute[text()='80']", in: document) == 1)
    #expect(try count("//sound[@tempo='120']", in: document) == 1, "the sound is always quarters")
}

@Test func theScoreFollowsTheMapBackToSeconds() {
    let score = ScoreDocument.build(notes: quarters(16) + quarters(3, from: 8, every: 2.0 / 3), grid: changing, key: nil)

    // 9 s is bar 5 (8 s in), one 90 BPM quarter (2/3 s) and a half further on: units 36.
    let position = score.measureIndex(atSeconds: 9, grid: changing)
    #expect(position?.measure == 4)
    #expect(abs((position?.units ?? 0) - 36) < 1e-9)
    #expect(abs(score.seconds(atMeasure: 4, units: 36, grid: changing) - 9) < 1e-9)
    #expect(score.measureIndex(atSeconds: 7.99, grid: changing)?.measure == 3)
}

// MARK: - MIDI

/// The bytes of the one-tempo writer before the map, captured with `data(notes:bpm:startOffsetSeconds:mode:)`
/// at 97 BPM with the downbeat at 0.7 s, and at 120 BPM from 0.
private let fixtureNotes: [NoteEvent] = [
    NoteEvent(startTime: 0.05, endTime: 0.61, pitch: 60, amplitude: 0.8, program: 0),
    NoteEvent(startTime: 0.70, endTime: 1.33, pitch: 64, amplitude: 0.55, program: 0),
    NoteEvent(startTime: 1.21, endTime: 2.9, pitch: 67, amplitude: 1.0, program: 33),
    NoteEvent(startTime: 2.47, endTime: 2.71, pitch: 38, amplitude: 0.9, program: NoteEvent.drumProgram),
    NoteEvent(startTime: 3.333, endTime: 5.01, pitch: 72, amplitude: 0.3, program: 0),
    NoteEvent(startTime: 7.77, endTime: 9.123, pitch: 48, amplitude: 0.66, program: 33),
]

private let fixture97 = "4d546864000000060001000403c04d54726b0000001300ff510309703d00ff58040402180800ff2f004d54726b0000002e00ff03055069616e6f00c000960f903c668665803c00810c90404687528040009824904826942b80480000ff2f004d54726b0000002300ff03044261737300c121a41891437f943e814300bb07913054903381300000ff2f004d54726b0000001a00ff03054472756d7300c900b33b992672827589260000ff2f00"

private let fixture120 = "4d546864000000060001000403c04d54726b0000001300ff510307a12000ff58040402180800ff2f004d54726b0000002d00ff03055069616e6f00c00060903c668833803c00812d904046893a8040009e05904826991480480000ff2f004d54726b0000002300ff03044261737300c121921391437f992d814300c906913054942681300000ff2f004d54726b0000001a00ff03054472756d7300c900a506992672834d89260000ff2f00"

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func aOneSegmentCommonGridWritesTheSameBytesAsBefore() {
    let at97 = TempoGrid(bpm: 97, offsetSeconds: 0.7, division: .sixteenth)
    #expect(hex(MidiFileWriter.data(notes: fixtureNotes, grid: at97, mode: .reuseChannels)) == fixture97)

    let at120 = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)
    #expect(hex(MidiFileWriter.data(notes: fixtureNotes, grid: at120, mode: .reuseChannels)) == fixture120)
}

@Test func aChangeAtBarFiveWritesASecondTempoAndMeter() {
    let data = [UInt8](MidiFileWriter.data(notes: [NoteEvent(startTime: 8, endTime: 9, pitch: 60, program: 0)],
                                           grid: changing, mode: .reuseChannels))
    // The conductor track: 120 and 4/4 at tick 0, then 90 and 3/4 at bar 5, 16 quarters in.
    let conductor = Array(data[22..<(22 + Int(data[21]))])
    let tempo90: [UInt8] = [0xFF, 0x51, 0x03, 0x0A, 0x2C, 0x2B]   // 666 667 µs
    let barFive = 16 * 960                                         // 15 360 = 0xF8 0x00 as a VLQ

    #expect(conductor.starts(with: [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))
    #expect(Array(conductor[15..<17]) == [0xF8, 0x00], "delta \(barFive)")
    #expect(Array(conductor[17..<23]) == tempo90)
    #expect(Array(conductor[23..<31]) == [0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08])

    // The note at 8 s is on bar 5's downbeat: tick 15 360 on the instrument track.
    let track = Array(data[(22 + Int(data[21]))...])
    #expect(track.indices.contains { track[$0...].starts(with: [0xF8, 0x00, 0x90, 0x3C]) })
}
