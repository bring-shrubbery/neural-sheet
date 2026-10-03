import Foundation

/// Writes a transcription as a MusicXML score (MusicXML design; arrangement design §5):
/// `score-partwise`, one part per instrument in the sidebar's order as the arrangement shows
/// it, in the grid's meters and tempos from the grid's downbeat (a `<time>` and a metronome
/// mark at each change, tempo map design §2), the notes quantized to the grid's division,
/// chords, ties, rests, each part in its clef and at its written transposition, a tab part
/// beside a fretted part's notation, a percussion staff for the drums, hidden parts left out,
/// and the sheet's title, credits and copyright.
///
/// The measures come from `ScoreDocument`, so the export and the Score tab agree by
/// construction. The rhythm lives in `MusicXMLWriter+Rhythm.swift`, the pitches in
/// `MusicXMLWriter+Pitch.swift`, the notation parts in `MusicXMLWriter+Parts.swift` and the tab
/// parts in `MusicXMLWriter+Tab.swift`; this file assembles the document.
public enum MusicXMLWriter {
    /// Units per quarter note: enough for 32nds and every dotted value between.
    public static let divisions = 24

    /// `quarterBeats` in units, to the nearest.
    static func units(quarterBeats: Double) -> Int {
        guard quarterBeats.isFinite else { return 0 }

        return Int((quarterBeats * Double(divisions)).rounded())
    }

    /// The whole document.
    ///
    /// - Parameters:
    ///   - ids: the document's ids alongside `notes`, or nil while a run streams.
    ///   - grid: the tempo, the downbeat and the division the notes are quantized to.
    ///   - key: the project key, or none for no signature; each part writes it transposed.
    ///   - title: the work title; nil takes the sheet's, then the take's name.
    ///   - arrangement: which parts show, how, and what the sheet says about itself.
    ///   - takeName: the take's name, the title of last resort.
    ///   - chords: the chord symbols, written as `<harmony>` on the first part (chord symbols design §2).
    ///   - markers: the section markers, written as `<rehearsal>` on the first part (markers and
    ///     lyrics design §2).
    public static func data(notes: [NoteEvent], ids: [NoteID?]? = nil, grid: TempoGrid, key: MusicalKey?,
                            title: String? = nil, arrangement: ScoreArrangement = ScoreArrangement(),
                            takeName: String? = nil, chords: [ChordEvent] = [], markers: [Marker] = []) -> Data {
        let document = ScoreDocument.build(notes: notes, ids: ids, grid: grid, key: key, arrangement: arrangement,
                                           chords: chords, markers: markers)
        let channels = channelMap(notes)
        let sheet = arrangement.sheet
        let workTitle = title ?? sheet.resolvedTitle(takeName: takeName)
        var xml = ""

        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n"
        xml += "<score-partwise version=\"4.0\">\n"

        if !workTitle.isEmpty {
            xml += "  <work><work-title>\(escaped(workTitle))</work-title></work>\n"
        }

        xml += "  <identification>\n"
        if !sheet.composer.isEmpty { xml += "    <creator type=\"composer\">\(escaped(sheet.composer))</creator>\n" }
        if !sheet.arranger.isEmpty { xml += "    <creator type=\"arranger\">\(escaped(sheet.arranger))</creator>\n" }
        if !sheet.copyright.isEmpty { xml += "    <rights>\(escaped(sheet.copyright))</rights>\n" }
        xml += "    <encoding><software>NeuralSheet</software></encoding>\n"
        xml += "  </identification>\n"

        if !sheet.subtitle.isEmpty {
            xml += "  <credit page=\"1\"><credit-type>subtitle</credit-type><credit-words>\(escaped(sheet.subtitle))</credit-words></credit>\n"
        }

        xml += "  <part-list>\n"

        for (index, part) in document.parts.enumerated() {
            let id = "P\(index + 1)"
            let channel = channels[part.program] ?? 1

            // The document decides what a part shows: a drum part has its staff whatever its mode.
            if !part.staves.isEmpty {
                xml += scorePartXML(id: id, name: part.name, program: part.program, channel: channel)
            }

            if part.tab != nil {
                xml += scorePartXML(id: "\(id)T", name: "\(part.name) (TAB)", program: part.program, channel: channel)
            }
        }

        if document.parts.isEmpty {
            // A score needs a part; an empty transcription gets one empty staff.
            xml += "    <score-part id=\"P1\"><part-name></part-name></score-part>\n"
        }

        xml += "  </part-list>\n"

        if document.parts.isEmpty {
            xml += notationPartXML(emptyPart(document.bars), id: "P1", bars: document.bars, writesTempo: true,
                                   chords: document.chords, rehearsals: document.rehearsalMarks)
        }

        var writesTempo = true

        for (index, part) in document.parts.enumerated() {
            let id = "P\(index + 1)"

            // The first part written carries the tempo marks, the chord symbols and the
            // rehearsal marks.
            if !part.staves.isEmpty {
                xml += notationPartXML(part, id: id, bars: document.bars, writesTempo: writesTempo,
                                       chords: writesTempo ? document.chords : [],
                                       rehearsals: writesTempo ? document.rehearsalMarks : [])
                writesTempo = false
            }

            if let tab = part.tab {
                xml += tabPartXML(tab, id: "\(id)T", fifths: document.fifths, bars: document.bars, writesTempo: writesTempo,
                                  chords: writesTempo ? document.chords : [],
                                  rehearsals: writesTempo ? document.rehearsalMarks : [])
                writesTempo = false
            }
        }

        xml += "</score-partwise>\n"

        return Data(xml.utf8)
    }

    /// The document with no arrangement and a plain key signature: `fifths` sharps (positive)
    /// or flats, 0 being no signature; black keys are spelled in flats for a flat key.
    public static func data(notes: [NoteEvent], grid: TempoGrid, fifths: Int = 0, title: String? = nil) -> Data {
        data(notes: notes, ids: nil, grid: grid, key: fifths == 0 ? nil : MusicalKey.major(fifths: fifths), title: title)
    }

    /// `"song_NNTranscription.musicxml"`, or `"NNTranscription.musicxml"` for a recorded take.
    public static func exportFileName(sourceFileNameWithoutExtension: String?) -> String {
        guard let name = sourceFileNameWithoutExtension, !name.isEmpty else {
            return "NNTranscription.musicxml"
        }

        return "\(name)_NNTranscription.musicxml"
    }

    // MARK: - The part list

    /// The MIDI channel of each program, as the MIDI file assigns them.
    private static func channelMap(_ notes: [NoteEvent]) -> [Int: Int] {
        var noteCounts: [Int: Int] = [:]

        for note in notes {
            noteCounts[note.program, default: 0] += 1
        }

        return MidiFileWriter.channelMap(programsAscending: noteCounts.keys.sorted(), noteCounts: noteCounts, mode: .reuseChannels)
    }

    private static func scorePartXML(id: String, name: String, program: Int, channel: Int) -> String {
        let midiProgram = program == NoteEvent.drumProgram ? 1 : program + 1
        var xml = ""

        xml += "    <score-part id=\"\(id)\">\n"
        xml += "      <part-name>\(escaped(name))</part-name>\n"
        xml += "      <score-instrument id=\"\(id)-I1\"><instrument-name>\(escaped(name))</instrument-name></score-instrument>\n"
        xml += "      <midi-instrument id=\"\(id)-I1\"><midi-channel>\(channel)</midi-channel><midi-program>\(midiProgram)</midi-program></midi-instrument>\n"
        xml += "    </score-part>\n"

        return xml
    }

    /// One treble staff of resting measures, for a transcription with nothing in it.
    private static func emptyPart(_ bars: [ScoreBar]) -> ScorePart {
        let measures = bars.map { ScoreDocument.measure(bar: $0, notes: [], transposition: 0, clef: .treble, isDrums: false, fifths: 0) }

        return ScorePart(program: 0, name: "", abbreviation: "", staves: [ScoreStaff(clef: .treble, measures: measures)])
    }

    // MARK: - Parts and measures

    /// One instrument's quantized notes, the score model's raw material.
    struct Part {
        var program: Int
        var name: String
        var channel: Int
        var notes: [UnitNote]

        var isDrums: Bool { program == NoteEvent.drumProgram }
    }

    /// The bars the score covers, as bar indices from the downbeat (bar 0 starts at the
    /// downbeat, the grid's bar 1; earlier bars are negative), found through the tempo map. One
    /// bar when there is nothing.
    static func measureSpan(_ parts: [Part], grid: TempoGrid) -> Range<Int> {
        let starts = parts.flatMap(\.notes).map(\.start)
        let ends = parts.flatMap(\.notes).map(\.end)

        guard let first = starts.min(), let last = ends.max() else { return 0 ..< 1 }

        let perQuarter = Double(divisions)
        let firstBar = grid.bar(atQuarterBeats: Double(first) / perQuarter) - 1
        let lastBar = grid.bar(atQuarterBeats: Double(max(last - 1, first)) / perQuarter)

        return firstBar ..< max(lastBar, firstBar + 1)
    }

    // MARK: - Text

    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }

        return result
    }
}
