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

@Test func newClefsHaveTheirBaselines() {
    #expect(Clef.alto.step(forStep: "F", octave: 3) == 0)
    #expect(Clef.alto.step(forStep: "C", octave: 4) == 4, "middle C on the alto's middle line")
    #expect(Clef.tenor.step(forStep: "D", octave: 3) == 0)
    #expect(Clef.tenor.step(forStep: "C", octave: 4) == 6, "middle C on the tenor's fourth line")
    #expect(Clef.treble8vb.step(forStep: "E", octave: 4) == 0, "the octave is in the transposition, not the clef")
    #expect(Clef.bass8vb.step(forStep: "G", octave: 2) == 0)
    #expect(Clef.treble8vb.isOctaveDown && Clef.bass8vb.isOctaveDown && !Clef.treble.isOctaveDown)
    // Alto and tenor signatures sit inside the staff, one position per letter.
    #expect(Clef.alto.signaturePositions(fifths: 1) == [7], "F♯ in the alto's top space")
    #expect(Clef.tenor.signaturePositions(fifths: -1) == [5], "B♭ in the tenor's third space")
    #expect(Clef.alto.signaturePositions(fifths: -3) == [3, 6, 2], "the alto's flats a step under the treble's")
    #expect(Clef.alto.signaturePositions(fifths: 3).count == 3)
}

@Test func clefChoicesResolve() {
    #expect(ClefChoice.automatic.resolve(for: [72, 74]) == [.treble])
    #expect(ClefChoice.automatic.resolve(for: [40, 43]) == [.bass])
    #expect(ClefChoice.grand.resolve(for: [60]) == [.treble, .bass])
    #expect(ClefChoice.alto.resolve(for: [60]) == [.alto])
    #expect(ClefChoice.treble8vb.resolve(for: [40]) == [.treble8vb])
    #expect(ClefChoice.percussion.resolve(for: []) == [.percussion])
}

@Test func keysTranspose() {
    #expect(MusicalKey(tonic: 0, mode: .major).transposed(by: 2) == MusicalKey(tonic: 2, mode: .major))
    #expect(MusicalKey(tonic: 0, mode: .minor).transposed(by: 9) == MusicalKey(tonic: 9, mode: .minor))
    #expect(MusicalKey(tonic: 5, mode: .major).transposed(by: -12) == MusicalKey(tonic: 5, mode: .major))
}

@Test func aTrumpetPartIsWrittenAToneUp() {
    var arrangement = ScoreArrangement()
    var trumpet = PartDisplay()
    trumpet.transposition = 2
    arrangement.parts[56] = trumpet

    let notes = [note(60, at: 0, program: 56), note(65, at: 0.5, program: 56)]
    let score = ScoreDocument.build(notes: notes, grid: grid, key: MusicalKey(tonic: 0, mode: .major), arrangement: arrangement)
    let part = score.parts[0]

    #expect(part.writtenFifths == 2, "C major sounds; D major is written")
    #expect(part.display.transposition == 2)
    let first = part.staves[0].measures[0].pieces[0].notes[0]
    #expect(first.pitch == 60 && first.writtenPitch == 62)
    #expect(first.step == -1, "D4 hangs just under the treble staff")
    #expect(first.accidental == nil)
    let second = part.staves[0].measures[0].pieces[1].notes[0]
    #expect(second.writtenPitch == 67 && second.accidental == nil, "G in D major")
}

@Test func aGuitarPartGetsATabStaffAndKeepsItsIds() {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.transposition = 12
    guitar.clef = .treble8vb
    guitar.tab = TabTemplate.template(id: "guitar")!.setup(preset: TabTemplate.template(id: "guitar")!.presets[0])
    guitar.strings = [NoteID(7): 1]
    arrangement.parts[24] = guitar

    let notes = [note(64, at: 0, program: 24), note(55, at: 0, program: 24), note(38, at: 0.5, program: 24)]
    let ids: [NoteID?] = [NoteID(7), NoteID(8), NoteID(9)]
    let score = ScoreDocument.build(notes: notes, ids: ids, grid: grid, key: nil, arrangement: arrangement)
    let part = score.parts[0]

    #expect(part.staves.map(\.clef) == [.treble8vb])
    #expect(part.tab?.tuning == [40, 45, 50, 55, 59, 64])

    let chord = part.tab!.measures[0].pieces[0]
    #expect(chord.notes.map(\.id) == [NoteID(8), NoteID(7)], "ascending pitch, ids carried")
    #expect(chord.notes[1].placement == .init(string: 1, fret: 19, isPlayable: true), "the manual choice")
    #expect(chord.notes[0].placement == .init(string: 3, fret: 0, isPlayable: true))

    let low = part.tab!.measures[0].pieces[1]
    #expect(low.notes[0].placement?.isPlayable == false, "D2 is below the guitar")

    // The notation staff shows the written octave: E4 sounding is written E5.
    #expect(part.staves[0].measures[0].pieces[0].notes.map(\.writtenPitch) == [67, 76])
}

@Test func tabOnlyAndHiddenParts() {
    var arrangement = ScoreArrangement()
    var bass = PartDisplay()
    bass.mode = .tab
    bass.tab = TabTemplate.template(id: "bass")!.setup(preset: TabTemplate.template(id: "bass")!.presets[0])
    arrangement.parts[33] = bass
    var hidden = PartDisplay()
    hidden.isHidden = true
    arrangement.parts[0] = hidden

    let score = ScoreDocument.build(notes: [note(43, at: 0, program: 33), note(60, at: 0)], grid: grid, key: nil, arrangement: arrangement)
    #expect(score.parts.map(\.program) == [33], "the piano is hidden")
    #expect(score.parts[0].staves.isEmpty)
    #expect(score.parts[0].tab != nil)
    #expect(score.measureCount == 1)
}

@Test func theOldBuildStillWorks() {
    let score = ScoreDocument.build(notes: [note(60, at: 0)], grid: grid, key: nil)
    #expect(score.parts[0].display == PartDisplay())
    #expect(score.parts[0].tab == nil)
    #expect(score.parts[0].staves[0].measures[0].pieces[0].notes[0].id == nil)
}
