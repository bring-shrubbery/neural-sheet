import Foundation
import Testing

@testable import NeuralSheetCore

private let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)

private func note(_ pitch: Int, at start: Double, length: Double = 0.5, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: start + length, pitch: pitch, program: program)
}

@Test func staffStepsCountFromTheBottomLine() {
    #expect(Clef.treble.step(forStep: "E", octave: 4) == 0)
    #expect(Clef.treble.step(forStep: "C", octave: 4) == -2, "middle C hangs below the treble staff")
    #expect(Clef.treble.step(forStep: "B", octave: 4) == 4, "the middle line")
    #expect(Clef.treble.step(forStep: "F", octave: 5) == 8, "the top line")
    #expect(Clef.bass.step(forStep: "G", octave: 2) == 0)
    #expect(Clef.bass.step(forStep: "C", octave: 4) == 10, "middle C sits above the bass staff")
    #expect(Clef.bass.step(forStep: "D", octave: 3) == 4)
    #expect(Clef.percussion.step(forStep: "C", octave: 5) == 5, "a snare on the third space")
}

@Test func keySignaturesSitOnTheirLines() {
    #expect(Clef.treble.signaturePositions(fifths: 2) == [8, 5], "F♯ on the top line, C♯ in the third space")
    #expect(Clef.treble.signaturePositions(fifths: -3) == [4, 7, 3], "B♭ E♭ A♭")
    #expect(Clef.bass.signaturePositions(fifths: 2) == [6, 3])
    #expect(Clef.bass.signaturePositions(fifths: -3) == [2, 5, 1])
    #expect(Clef.treble.signaturePositions(fifths: 0).isEmpty)
    #expect(MusicalKey.alteredSteps(fifths: 1) == ["F": 1])
    #expect(MusicalKey.alteredSteps(fifths: -2) == ["B": -1, "E": -1])
    #expect(MusicalKey(tonic: 2, mode: .major).alteredSteps == ["F": 1, "C": 1])
}

@Test func accidentalsFollowTheSignature() {
    #expect(ScorePitch.accidental(letter: "F", alter: 1, fifths: 0) == .sharp)
    #expect(ScorePitch.accidental(letter: "F", alter: 1, fifths: 1) == nil, "F♯ is in G major")
    #expect(ScorePitch.accidental(letter: "F", alter: 0, fifths: 1) == .natural)
    #expect(ScorePitch.accidental(letter: "B", alter: -1, fifths: -1) == nil)
    #expect(ScorePitch.accidental(letter: "B", alter: -1, fifths: 0) == .flat)
    #expect(ScorePitch.accidental(letter: "G", alter: 0, fifths: 0) == nil)
}

@Test func aScaleIsEightQuartersOverTwoMeasures() {
    let scale = [60, 62, 64, 65, 67, 69, 71, 72].enumerated().map { note($1, at: Double($0) * 0.5) }
    let score = ScoreDocument.build(notes: scale, grid: grid, key: MusicalKey(tonic: 0, mode: .major))

    #expect(score.parts.count == 1)
    #expect(score.measureCount == 2)
    #expect(score.firstBar == 0)
    #expect(score.parts[0].staves.count == 1)
    #expect(score.parts[0].staves[0].clef == .treble)

    let measures = score.parts[0].staves[0].measures
    #expect(measures.count == 2)
    #expect(measures[0].pieces.count == 4)
    let allQuarters = measures[0].pieces.allSatisfy { $0.type == "quarter" && $0.notes.count == 1 && $0.accidental == nil }
    #expect(allQuarters)
    #expect(measures[0].pieces.map(\.startUnits) == [0, 24, 48, 72])
    #expect(measures[0].pieces[0].notes[0].step == -2, "middle C")
    #expect(measures[1].pieces[3].notes[0].step == 5, "C5 in the third space")
    #expect(measures[0].pieces[0].hasStem && measures[0].pieces[0].flags == 0 && !measures[0].pieces[0].isHollow)
}

private extension ScorePiece {
    var accidental: Accidental? { notes.first?.accidental }
}

@Test func tiesChordsRestsAndAccidentals() {
    let score = ScoreDocument.build(notes: [
        note(66, at: 1.5, length: 1.0),                 // F♯ across the bar line
        note(60, at: 0, length: 0.5), note(64, at: 0, length: 0.5),   // a chord on the downbeat
        note(72, at: 8, length: 0.25),                  // an 8th two bars later
    ], grid: grid, key: nil)

    let measures = score.parts[0].staves[0].measures
    #expect(score.measureCount == 5)

    let chord = measures[0].pieces[0]
    #expect(chord.notes.map(\.pitch) == [60, 64])
    #expect(chord.notes.map(\.step) == [-2, 0])

    let firstHalf = measures[0].pieces.last!
    #expect(firstHalf.notes.count == 1 && firstHalf.notes[0].tiedTo && !firstHalf.notes[0].tiedFrom)
    #expect(firstHalf.notes[0].accidental == .sharp)
    #expect(firstHalf.type == "quarter" && firstHalf.startUnits == 72)

    let secondHalf = measures[1].pieces[0]
    #expect(secondHalf.notes[0].tiedFrom && !secondHalf.notes[0].tiedTo)
    #expect(secondHalf.type == "quarter" && secondHalf.startUnits == 0)

    // A rest fills the rest of measure 2, and measures 3 and 4 are whole-measure rests.
    let restOfMeasureTwo = measures[1].pieces.dropFirst().allSatisfy(\.isRest)
    #expect(restOfMeasureTwo)
    #expect(measures[2].pieces == [ScorePiece(startUnits: 0, units: 96, type: "whole", dots: 0, notes: [], isWholeMeasureRest: true)])
    #expect(measures[3].pieces[0].isWholeMeasureRest)
    #expect(measures[4].pieces[0].type == "eighth" && measures[4].pieces[0].flags == 1)
}

@Test func drumsAndAGrandStaff() {
    var notes = [
        note(36, at: 0, length: 0.1, program: NoteEvent.drumProgram),
        note(42, at: 0.5, length: 0.1, program: NoteEvent.drumProgram),
    ]
    for index in 0..<8 {
        notes.append(note(72, at: Double(index) * 0.5))
        notes.append(note(48, at: Double(index) * 0.5))
    }

    let score = ScoreDocument.build(notes: notes, grid: grid, key: nil)
    #expect(score.parts.map(\.name) == ["Piano", "Drums"])

    let piano = score.parts[0]
    #expect(piano.staves.map(\.clef) == [.treble, .bass])
    #expect(piano.staves[0].measures[0].pieces[0].notes.map(\.pitch) == [72])
    #expect(piano.staves[1].measures[0].pieces[0].notes.map(\.pitch) == [48])
    #expect(piano.staves[1].measures[0].pieces[0].notes[0].step == 3, "C3 in the bass staff's second space")

    let drums = score.parts[1].staves[0]
    #expect(drums.clef == .percussion)
    #expect(drums.measures[0].pieces[0].notes[0].head == .normal, "a kick")
    #expect(drums.measures[0].pieces[0].notes[0].step == 1, "F4 in the first space")
    let hiHat = drums.measures[0].pieces.first { !$0.isRest && $0.notes[0].pitch == 42 }
    #expect(hiHat?.notes[0].head == .x, "a hi-hat")
}

@Test func measureTimesInvert() {
    let offsetGrid = TempoGrid(bpm: 100, offsetSeconds: 1.0, division: .eighth)
    let score = ScoreDocument.build(notes: [note(60, at: 0.4), note(60, at: 5)], grid: offsetGrid, key: nil)

    #expect(score.firstBar == -1, "a note before the downbeat starts the score a bar early")
    #expect(score.measureCount == 3)

    let position = score.measureIndex(atSeconds: 1.0, grid: offsetGrid)
    #expect(position?.measure == 1 && position?.units == 0, "the downbeat is the start of measure 2")

    let later = score.measureIndex(atSeconds: 1.6, grid: offsetGrid)
    #expect(later?.measure == 1)
    #expect(abs((later?.units ?? 0) - 24) < 1e-9, "a beat in")

    #expect(score.measureIndex(atSeconds: 100, grid: offsetGrid) == nil)
    #expect(abs(score.seconds(atMeasure: 1, units: 24, grid: offsetGrid) - 1.6) < 1e-9)
    #expect(score.seconds(atMeasure: 0, units: 0, grid: offsetGrid) == 0, "measure 1 begins before the take: clamped")
}
