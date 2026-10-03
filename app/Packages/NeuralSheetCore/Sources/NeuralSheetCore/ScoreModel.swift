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
    /// The first measure's tempo.
    public var bpm: Double
    /// Each measure's place in time, meter and tempo (tempo map design §2), one per measure.
    public var bars: [ScoreBar] = []

    /// The empty score: no parts, no measures.
    public static let empty = ScoreDocument(parts: [], measureCount: 0, firstBar: 0, fifths: 0, bpm: TempoGrid.defaultBpm)

    /// The score for `notes` on `grid` in `key`, shown as `arrangement` says: hidden parts left
    /// out, each part at its written transposition, in its clefs, with a tab staff when it has
    /// a template. `ids` runs alongside `notes` (the document's) or is nil while a run streams.
    /// The grid's swing is dropped: it is a feel, not notation, so the Score tab and both score
    /// exports quantize to the straight grid (editor commands design §2).
    public static func build(notes: [NoteEvent], ids: [NoteID?]? = nil, grid: TempoGrid, key: MusicalKey?,
                             arrangement: ScoreArrangement = ScoreArrangement()) -> ScoreDocument {
        let grid = grid.straight
        var notesByProgram: [Int: [(NoteEvent, NoteID?)]] = [:]

        for (index, note) in notes.enumerated() {
            let id = ids.flatMap { index < $0.count ? $0[index] : nil }
            notesByProgram[note.program, default: []].append((note, id))
        }

        let programs = notesByProgram.keys.sorted().filter { !arrangement.display(for: $0).isHidden }

        let writerParts = programs.map { program -> MusicXMLWriter.Part in
            let pairs = notesByProgram[program] ?? []
            return MusicXMLWriter.Part(program: program,
                                       name: Instruments.info(forProgram: program).name,
                                       channel: 1,
                                       notes: MusicXMLWriter.unitNotes(pairs.map(\.0), ids: pairs.map(\.1), grid: grid))
        }

        let span = MusicXMLWriter.measureSpan(writerParts, grid: grid)
        let bars = ScoreBar.table(span, grid: grid)

        let parts = writerParts.map { part -> ScorePart in
            let info = Instruments.info(forProgram: part.program)
            let display = arrangement.display(for: part.program)
            let isDrums = part.program == NoteEvent.drumProgram
            let transposition = isDrums ? 0 : display.transposition
            let writtenKey = key?.transposed(by: transposition)
            let fifths = writtenKey?.fifths ?? 0
            let written = part.notes.map { note in
                var shifted = note
                shifted.pitch = min(max(note.pitch + transposition, 0), 127)
                return shifted
            }

            var staves: [ScoreStaff] = []

            // Drums have no tab, so a drum part is notation whatever its mode says: a template
            // and Tab left over from another instrument must not lose it its staff.
            if display.showsNotation || isDrums {
                let clefs: [Clef] = isDrums ? [.percussion] : display.clef.resolve(for: written.map(\.pitch))
                let staffNotes: [(Clef, [MusicXMLWriter.UnitNote])] = clefs.count == 2
                    ? [(clefs[0], written.filter { $0.pitch >= MusicXMLWriter.middleC }),
                       (clefs[1], written.filter { $0.pitch < MusicXMLWriter.middleC })]
                    : [(clefs[0], written)]

                staves = staffNotes.map { clef, unitNotes in
                    ScoreStaff(clef: clef, measures: bars.map { bar in
                        measure(bar: bar, notes: unitNotes, transposition: transposition, clef: clef, isDrums: isDrums, fifths: fifths)
                    })
                }
            }

            var tab: ScoreTabStaff?

            if let setup = display.tab, display.showsTab, !isDrums {
                tab = ScoreTabStaff(tuning: setup.tuning, frets: setup.frets, measures: bars.map { bar in
                    tabMeasure(bar: bar, notes: part.notes, setup: setup, manual: display.strings)
                })
            }

            var scorePart = ScorePart(program: part.program, name: info.name, abbreviation: info.abbreviation, staves: staves)
            scorePart.display = display
            scorePart.tab = tab
            scorePart.writtenFifths = fifths

            return scorePart
        }

        return ScoreDocument(parts: parts, measureCount: span.count, firstBar: span.lowerBound, fifths: key?.fifths ?? 0,
                             bpm: bars.first?.bpm ?? grid.bpm, bars: bars)
    }

    /// One bar as pieces: the export's segments of `notes` over the bar, each split into printable
    /// values; an empty bar is one whole-measure rest. `scoreNotes(segment, pieceStart, pieceEnd)`
    /// gives the notes of one piece of `segment`.
    static func pieces(bar: ScoreBar, notes: [MusicXMLWriter.UnitNote],
                       scoreNotes: (_ segment: MusicXMLWriter.Segment, _ pieceStart: Int, _ pieceEnd: Int) -> [ScoreNote]) -> ScoreMeasure {
        let from = bar.startUnits
        let to = bar.endUnits
        var pieces: [ScorePiece] = []

        for segment in MusicXMLWriter.segments(notes, from: from, to: to) {
            if segment.isRest, segment.start == from, segment.end == to {
                pieces.append(ScorePiece(startUnits: 0, units: bar.lengthUnits, type: "whole", dots: 0,
                                         notes: [], isWholeMeasureRest: true))
                continue
            }

            var pieceStart = segment.start

            for value in MusicXMLWriter.printableDurations(segment.end - segment.start) {
                let pieceEnd = pieceStart + value.units

                pieces.append(ScorePiece(startUnits: pieceStart - from, units: value.units, type: value.type, dots: value.dots,
                                         notes: scoreNotes(segment, pieceStart, pieceEnd), isWholeMeasureRest: false))
                pieceStart = pieceEnd
            }
        }

        return ScoreMeasure(pieces: pieces, lengthUnits: bar.lengthUnits,
                            timeSignature: bar.showsTimeSignature ? bar.timeSignature : nil,
                            tempo: bar.showsTempo ? bar.bpm : nil)
    }

    /// One bar of one staff. `notes` are the written unit notes; each note sounds `transposition`
    /// semitones lower.
    static func measure(bar: ScoreBar, notes: [MusicXMLWriter.UnitNote], transposition: Int, clef: Clef, isDrums: Bool, fifths: Int) -> ScoreMeasure {
        pieces(bar: bar, notes: notes) { segment, pieceStart, pieceEnd in
            segment.notes.map { note -> ScoreNote in
                if isDrums {
                    let display = MusicXMLWriter.drumDisplay(note: note.pitch)
                    return ScoreNote(pitch: note.pitch - transposition,
                                     step: clef.step(forStep: display.step, octave: display.octave),
                                     accidental: nil,
                                     tiedFrom: note.start < pieceStart,
                                     tiedTo: note.end > pieceEnd,
                                     head: ScoreNote.Head(notehead: display.notehead),
                                     id: note.id,
                                     writtenPitch: note.pitch)
                }

                let spelled = MusicXMLWriter.spelling(midi: note.pitch, preferFlats: fifths < 0)
                return ScoreNote(pitch: note.pitch - transposition,
                                 step: clef.step(forStep: spelled.step, octave: spelled.octave),
                                 accidental: ScorePitch.accidental(letter: spelled.step, alter: spelled.alter, fifths: fifths),
                                 tiedFrom: note.start < pieceStart,
                                 tiedTo: note.end > pieceEnd,
                                 head: .normal,
                                 id: note.id,
                                 writtenPitch: note.pitch)
            }
        }
    }

    /// One bar of a tab staff: the same pieces as the notation, each chord's notes placed on
    /// strings. `notes` are the sounding unit notes; a note's `step` is its string (the renderer
    /// draws the fret on that line).
    static func tabMeasure(bar: ScoreBar, notes: [MusicXMLWriter.UnitNote], setup: TabSetup, manual: [NoteID: Int]) -> ScoreMeasure {
        pieces(bar: bar, notes: notes) { segment, pieceStart, pieceEnd in
            let placements = TabFingering.place(pitches: segment.notes.map(\.pitch), tuning: setup.tuning, frets: setup.frets,
                                                manual: segment.notes.map { $0.id.flatMap { manual[$0] } })

            return segment.notes.enumerated().map { index, note in
                ScoreNote(pitch: note.pitch, step: placements[index].string, accidental: nil,
                          tiedFrom: note.start < pieceStart, tiedTo: note.end > pieceEnd, head: .normal,
                          id: note.id, writtenPitch: note.pitch, placement: placements[index])
            }
        }
    }
}

public struct ScorePart: Equatable, Sendable {
    public var program: Int
    public var name: String
    public var abbreviation: String
    public var staves: [ScoreStaff]
    public var display: PartDisplay = PartDisplay()
    /// Beside the staves when the part shows tab.
    public var tab: ScoreTabStaff? = nil
    /// The written key's signature: the project key's, transposed with the part.
    public var writtenFifths: Int = 0
}

/// A part's tablature: the same pieces as its staves, each note placed on a string.
public struct ScoreTabStaff: Equatable, Sendable {
    public var tuning: [Int]
    public var frets: Int
    public var measures: [ScoreMeasure]
}

public struct ScoreStaff: Equatable, Sendable {
    public var clef: Clef
    public var measures: [ScoreMeasure]
}

public struct ScoreMeasure: Equatable, Sendable {
    public var pieces: [ScorePiece]
    /// The bar's length in units: 96 for 4/4, 72 for 3/4 and 6/8.
    public var lengthUnits: Int = MusicXMLWriter.divisions * 4
    /// The meter, on the first measure and wherever it changes; nil elsewhere.
    public var timeSignature: TimeSignature? = nil
    /// The quarter-note tempo, on the first measure and wherever it changes; nil elsewhere.
    public var tempo: Double? = nil
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

    /// The sounding pitch: what plays, and what the tab and the cursor use.
    public var pitch: Int
    /// Staff steps from the bottom line, a step per line or space; on a tab staff, the string.
    public var step: Int
    public var accidental: Accidental?
    public var tiedFrom: Bool
    public var tiedTo: Bool
    public var head: Head
    /// The document's, nil while a run streams.
    public var id: NoteID? = nil
    /// What the staff shows: the sounding pitch plus the part's transposition.
    public var writtenPitch: Int = 0
    /// On a tab staff, the string and fret.
    public var placement: TabFingering.Placement? = nil
}
