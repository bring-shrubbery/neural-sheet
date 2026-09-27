import Foundation

/// The transcription as staff notation (score design §3): the same quantization, segmentation,
/// staves and spelling the MusicXML export uses, arranged as parts, staves, measures and pieces
/// with their staff positions, for the Score tab to lay out and draw.
public struct ScoreDocument: Equatable, Sendable {
    public var parts: [ScorePart]
    public var measureCount: Int
    /// The bar index (from the grid's downbeat) that measure 1 stands for; 0 or negative when
    /// notes precede the downbeat.
    public var firstBar: Int
    public var fifths: Int
    public var bpm: Double

    /// The empty score: no parts, no measures.
    public static let empty = ScoreDocument(parts: [], measureCount: 0, firstBar: 0, fifths: 0, bpm: TempoGrid.defaultBpm)

    /// The score for `notes` on `grid` in `key`.
    public static func build(notes: [NoteEvent], grid: TempoGrid, key: MusicalKey?) -> ScoreDocument {
        var notesByProgram: [Int: [NoteEvent]] = [:]

        for note in notes {
            notesByProgram[note.program, default: []].append(note)
        }

        let fifths = key?.fifths ?? 0
        let quantum = MusicXMLWriter.quantum(for: grid.division)
        let programs = notesByProgram.keys.sorted()

        let writerParts = programs.map { program in
            MusicXMLWriter.Part(program: program,
                                name: Instruments.info(forProgram: program).name,
                                channel: 1,
                                notes: MusicXMLWriter.unitNotes(notesByProgram[program] ?? [], grid: grid, quantum: quantum))
        }

        let span = MusicXMLWriter.measureSpan(writerParts)

        let parts = writerParts.map { part -> ScorePart in
            let info = Instruments.info(forProgram: part.program)
            let isDrums = part.program == NoteEvent.drumProgram
            let layout: MusicXMLWriter.StaffLayout = isDrums ? .percussion : MusicXMLWriter.staffLayout(for: part.notes.map(\.pitch))

            let staffNotes: [(Clef, [MusicXMLWriter.UnitNote])]
            switch layout {
            case .treble: staffNotes = [(.treble, part.notes)]
            case .bass: staffNotes = [(.bass, part.notes)]
            case .percussion: staffNotes = [(.percussion, part.notes)]
            case .grand:
                staffNotes = [(.treble, part.notes.filter { $0.pitch >= MusicXMLWriter.middleC }),
                              (.bass, part.notes.filter { $0.pitch < MusicXMLWriter.middleC })]
            }

            let staves = staffNotes.map { clef, notes in
                ScoreStaff(clef: clef, measures: span.map { bar in
                    measure(bar: bar, notes: notes, clef: clef, isDrums: isDrums, fifths: fifths)
                })
            }

            return ScorePart(program: part.program, name: info.name, abbreviation: info.abbreviation, staves: staves)
        }

        return ScoreDocument(parts: parts, measureCount: span.count, firstBar: span.lowerBound, fifths: fifths, bpm: grid.bpm)
    }

    /// One bar of one staff: the export's segments, each split into printable values, as pieces.
    static func measure(bar: Int, notes: [MusicXMLWriter.UnitNote], clef: Clef, isDrums: Bool, fifths: Int) -> ScoreMeasure {
        let from = bar * MusicXMLWriter.barUnits
        let to = from + MusicXMLWriter.barUnits
        var pieces: [ScorePiece] = []

        for segment in MusicXMLWriter.segments(notes, from: from, to: to) {
            if segment.isRest, segment.start == from, segment.end == to {
                pieces.append(ScorePiece(startUnits: 0, units: MusicXMLWriter.barUnits, type: "whole", dots: 0,
                                         notes: [], isWholeMeasureRest: true))
                continue
            }

            var pieceStart = segment.start

            for value in MusicXMLWriter.printableDurations(segment.end - segment.start) {
                let pieceEnd = pieceStart + value.units

                let scoreNotes = segment.notes.map { note -> ScoreNote in
                    if isDrums {
                        let display = MusicXMLWriter.drumDisplay(note: note.pitch)
                        return ScoreNote(pitch: note.pitch,
                                         step: clef.step(forStep: display.step, octave: display.octave),
                                         accidental: nil,
                                         tiedFrom: note.start < pieceStart,
                                         tiedTo: note.end > pieceEnd,
                                         head: ScoreNote.Head(notehead: display.notehead))
                    }

                    let spelled = MusicXMLWriter.spelling(midi: note.pitch, preferFlats: fifths < 0)
                    return ScoreNote(pitch: note.pitch,
                                     step: clef.step(forStep: spelled.step, octave: spelled.octave),
                                     accidental: ScorePitch.accidental(letter: spelled.step, alter: spelled.alter, fifths: fifths),
                                     tiedFrom: note.start < pieceStart,
                                     tiedTo: note.end > pieceEnd,
                                     head: .normal)
                }

                pieces.append(ScorePiece(startUnits: pieceStart - from, units: value.units, type: value.type, dots: value.dots,
                                         notes: scoreNotes, isWholeMeasureRest: false))
                pieceStart = pieceEnd
            }
        }

        return ScoreMeasure(pieces: pieces)
    }

    // MARK: - Time

    /// The measure (0-based) and the position in it, in units, at `seconds`; nil before the first
    /// measure or past the last.
    public func measureIndex(atSeconds seconds: Double, grid: TempoGrid) -> (measure: Int, units: Double)? {
        let unitsFromDownbeat = (seconds - grid.offsetSeconds) / grid.secondsPerBeat * Double(MusicXMLWriter.divisions)
        let barsFromDownbeat = unitsFromDownbeat / Double(MusicXMLWriter.barUnits)
        let measure = Int(barsFromDownbeat.rounded(.down)) - firstBar

        guard measure >= 0, measure < measureCount else { return nil }

        let units = unitsFromDownbeat - Double(firstBar + measure) * Double(MusicXMLWriter.barUnits)

        return (measure, units)
    }

    /// The seconds at `units` into measure `measure` (0-based), never before 0.
    public func seconds(atMeasure measure: Int, units: Double, grid: TempoGrid) -> Double {
        let unitsFromDownbeat = Double(firstBar + measure) * Double(MusicXMLWriter.barUnits) + units

        return max(0, grid.offsetSeconds + unitsFromDownbeat / Double(MusicXMLWriter.divisions) * grid.secondsPerBeat)
    }
}

public struct ScorePart: Equatable, Sendable {
    public var program: Int
    public var name: String
    public var abbreviation: String
    public var staves: [ScoreStaff]
}

public struct ScoreStaff: Equatable, Sendable {
    public var clef: Clef
    public var measures: [ScoreMeasure]
}

public struct ScoreMeasure: Equatable, Sendable {
    public var pieces: [ScorePiece]
}

/// One chord or rest of one printable value.
public struct ScorePiece: Equatable, Sendable {
    /// Units from the start of the measure.
    public var startUnits: Int
    public var units: Int
    /// whole, half, quarter, eighth, 16th, 32nd.
    public var type: String
    public var dots: Int
    /// Ascending by step; empty for a rest.
    public var notes: [ScoreNote]
    public var isWholeMeasureRest: Bool

    public var isRest: Bool { notes.isEmpty }

    /// How many flags a stemmed note of this value carries.
    public var flags: Int {
        switch type {
        case "eighth": 1
        case "16th": 2
        case "32nd": 3
        default: 0
        }
    }

    public var hasStem: Bool { type != "whole" }
    public var isHollow: Bool { type == "whole" || type == "half" }
}

public struct ScoreNote: Equatable, Sendable {
    public enum Head: Equatable, Sendable {
        case normal, x, diamond, triangle

        init(notehead: String?) {
            switch notehead {
            case "x": self = .x
            case "diamond": self = .diamond
            case "triangle": self = .triangle
            default: self = .normal
            }
        }
    }

    public var pitch: Int
    /// Staff steps from the bottom line, a step per line or space.
    public var step: Int
    public var accidental: Accidental?
    public var tiedFrom: Bool
    public var tiedTo: Bool
    public var head: Head
}
