import Foundation

/// Writes a transcription as a MusicXML score (MusicXML design): `score-partwise`, one part per
/// instrument in the sidebar's order, 4/4 at the grid's tempo from the grid's downbeat, the
/// notes quantized to the grid's division, chords, ties, rests, a clef by range or two staves,
/// and a percussion staff for the drums.
///
/// The rhythm lives in `MusicXMLWriter+Rhythm.swift`, the pitches in `MusicXMLWriter+Pitch.swift`;
/// this file assembles the document.
public enum MusicXMLWriter {
    /// Units per quarter note: enough for 32nds and every dotted value between.
    public static let divisions = 24
    /// A 4/4 bar in units.
    public static let barUnits = divisions * TempoGrid.beatsPerBar

    /// The whole document.
    ///
    /// - Parameters:
    ///   - grid: the tempo, the downbeat and the division the notes are quantized to.
    ///   - fifths: the key signature as sharps (positive) or flats; 0 is C major. Black keys are
    ///     spelled in flats for a flat key.
    ///   - title: the work title, or none.
    public static func data(notes: [NoteEvent], grid: TempoGrid, fifths: Int = 0, title: String? = nil) -> Data {
        var noteCounts: [Int: Int] = [:]
        var notesByProgram: [Int: [NoteEvent]] = [:]

        for note in notes {
            noteCounts[note.program, default: 0] += 1
            notesByProgram[note.program, default: []].append(note)
        }

        let channels = MidiFileWriter.channelMap(
            programsAscending: noteCounts.keys.sorted(), noteCounts: noteCounts, mode: .reuseChannels)
        // Ascending program, drums last: the sidebar's order, and the MIDI file's.
        let programs = notesByProgram.keys.sorted()
        let step = quantum(for: grid.division)

        let parts = programs.map { program in
            Part(program: program,
                 name: Instruments.info(forProgram: program).name,
                 channel: channels[program] ?? 1,
                 notes: unitNotes(notesByProgram[program] ?? [], grid: grid, quantum: step))
        }

        let span = measureSpan(parts)
        var xml = ""

        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n"
        xml += "<score-partwise version=\"4.0\">\n"

        if let title, !title.isEmpty {
            xml += "  <work><work-title>\(escaped(title))</work-title></work>\n"
        }

        xml += "  <identification><encoding><software>NeuralSheet</software></encoding></identification>\n"
        xml += "  <part-list>\n"

        for (index, part) in parts.enumerated() {
            let id = "P\(index + 1)"
            let program = part.program == NoteEvent.drumProgram ? 1 : part.program + 1

            xml += "    <score-part id=\"\(id)\">\n"
            xml += "      <part-name>\(escaped(part.name))</part-name>\n"
            xml += "      <score-instrument id=\"\(id)-I1\"><instrument-name>\(escaped(part.name))</instrument-name></score-instrument>\n"
            xml += "      <midi-instrument id=\"\(id)-I1\"><midi-channel>\(part.channel)</midi-channel><midi-program>\(program)</midi-program></midi-instrument>\n"
            xml += "    </score-part>\n"
        }

        if parts.isEmpty {
            // A score needs a part; an empty transcription gets one empty staff.
            xml += "    <score-part id=\"P1\"><part-name></part-name></score-part>\n"
        }

        xml += "  </part-list>\n"

        if parts.isEmpty {
            xml += partXML(Part(program: 0, name: "", channel: 1, notes: []), id: "P1", span: span, grid: grid,
                           fifths: fifths, isFirst: true)
        }

        for (index, part) in parts.enumerated() {
            xml += partXML(part, id: "P\(index + 1)", span: span, grid: grid, fifths: fifths, isFirst: index == 0)
        }

        xml += "</score-partwise>\n"

        return Data(xml.utf8)
    }

    /// `"song_NNTranscription.musicxml"`, or `"NNTranscription.musicxml"` for a recorded take.
    public static func exportFileName(sourceFileNameWithoutExtension: String?) -> String {
        guard let name = sourceFileNameWithoutExtension, !name.isEmpty else {
            return "NNTranscription.musicxml"
        }

        return "\(name)_NNTranscription.musicxml"
    }

    // MARK: - Parts and measures

    struct Part {
        var program: Int
        var name: String
        var channel: Int
        var notes: [UnitNote]

        var isDrums: Bool { program == NoteEvent.drumProgram }
    }

    /// The bars the score covers, as bar indices from the downbeat (bar 0 starts at the
    /// downbeat; earlier bars are negative). One bar when there is nothing.
    static func measureSpan(_ parts: [Part]) -> Range<Int> {
        let starts = parts.flatMap(\.notes).map(\.start)
        let ends = parts.flatMap(\.notes).map(\.end)

        guard let first = starts.min(), let last = ends.max() else { return 0 ..< 1 }

        let firstBar = Int((Double(first) / Double(barUnits)).rounded(.down))
        let lastBar = Int((Double(last) / Double(barUnits)).rounded(.up))

        return firstBar ..< max(lastBar, firstBar + 1)
    }

    private static func partXML(_ part: Part, id: String, span: Range<Int>, grid: TempoGrid, fifths: Int,
                                isFirst: Bool) -> String {
        let layout: StaffLayout = part.isDrums ? .percussion : staffLayout(for: part.notes.map(\.pitch))
        let preferFlats = fifths < 0
        var xml = "  <part id=\"\(id)\">\n"

        // Two staves split at middle C; one staff takes everything.
        let staffNotes: [[UnitNote]] = layout == .grand
            ? [part.notes.filter { $0.pitch >= middleC }, part.notes.filter { $0.pitch < middleC }]
            : [part.notes]

        for (measureIndex, bar) in span.enumerated() {
            let from = bar * barUnits
            let to = from + barUnits

            xml += "    <measure number=\"\(measureIndex + 1)\">\n"

            if measureIndex == 0 {
                xml += "      <attributes>\n"
                xml += "        <divisions>\(divisions)</divisions>\n"
                xml += "        <key><fifths>\(fifths)</fifths></key>\n"
                xml += "        <time><beats>\(TempoGrid.beatsPerBar)</beats><beat-type>4</beat-type></time>\n"

                switch layout {
                case .treble:
                    xml += "        <clef><sign>G</sign><line>2</line></clef>\n"
                case .bass:
                    xml += "        <clef><sign>F</sign><line>4</line></clef>\n"
                case .grand:
                    xml += "        <staves>2</staves>\n"
                    xml += "        <clef number=\"1\"><sign>G</sign><line>2</line></clef>\n"
                    xml += "        <clef number=\"2\"><sign>F</sign><line>4</line></clef>\n"
                case .percussion:
                    xml += "        <clef><sign>percussion</sign><line>2</line></clef>\n"
                }

                xml += "      </attributes>\n"

                if isFirst {
                    let bpm = Int(TempoGrid.clampedBpm(grid.bpm).rounded())
                    xml += "      <direction placement=\"above\"><direction-type><metronome><beat-unit>quarter</beat-unit>"
                    xml += "<per-minute>\(bpm)</per-minute></metronome></direction-type><sound tempo=\"\(bpm)\"/></direction>\n"
                }
            }

            for (staffIndex, notes) in staffNotes.enumerated() {
                if staffIndex > 0 {
                    xml += "      <backup><duration>\(barUnits)</duration></backup>\n"
                }

                let staff = layout.staves > 1 ? staffIndex + 1 : nil
                let voice = staffIndex + 1

                for segment in segments(notes, from: from, to: to) {
                    xml += segmentXML(segment, measureStart: from, voice: voice, staff: staff,
                                      isDrums: part.isDrums, preferFlats: preferFlats)
                }
            }

            xml += "    </measure>\n"
        }

        xml += "  </part>\n"

        return xml
    }

    // MARK: - Notes and rests

    private static func segmentXML(_ segment: Segment, measureStart: Int, voice: Int, staff: Int?,
                                   isDrums: Bool, preferFlats: Bool) -> String {
        var xml = ""

        if segment.isRest {
            if segment.start == measureStart, segment.end - segment.start == barUnits {
                xml += "      <note><rest measure=\"yes\"/><duration>\(barUnits)</duration><voice>\(voice)</voice>"
                xml += staff.map { "<staff>\($0)</staff>" } ?? ""
                xml += "</note>\n"
                return xml
            }

            for value in printableDurations(segment.end - segment.start) {
                xml += "      <note><rest/><duration>\(value.units)</duration><voice>\(voice)</voice><type>\(value.type)</type>"
                xml += String(repeating: "<dot/>", count: value.dots)
                xml += staff.map { "<staff>\($0)</staff>" } ?? ""
                xml += "</note>\n"
            }

            return xml
        }

        // A segment longer than one printable value is several chords tied together.
        var pieceStart = segment.start

        for value in printableDurations(segment.end - segment.start) {
            let pieceEnd = pieceStart + value.units

            for (index, note) in segment.notes.enumerated() {
                let tiedFrom = note.start < pieceStart
                let tiedTo = note.end > pieceEnd

                xml += "      <note>"
                if index > 0 { xml += "<chord/>" }

                if isDrums {
                    let display = drumDisplay(note: note.pitch)
                    xml += "<unpitched><display-step>\(display.step)</display-step><display-octave>\(display.octave)</display-octave></unpitched>"
                } else {
                    let spelled = spelling(midi: note.pitch, preferFlats: preferFlats)
                    xml += "<pitch><step>\(spelled.step)</step>"
                    if spelled.alter != 0 { xml += "<alter>\(spelled.alter)</alter>" }
                    xml += "<octave>\(spelled.octave)</octave></pitch>"
                }

                xml += "<duration>\(value.units)</duration>"
                if tiedFrom { xml += "<tie type=\"stop\"/>" }
                if tiedTo { xml += "<tie type=\"start\"/>" }
                xml += "<voice>\(voice)</voice><type>\(value.type)</type>"
                xml += String(repeating: "<dot/>", count: value.dots)

                if isDrums, let head = drumDisplay(note: note.pitch).notehead {
                    xml += "<notehead>\(head)</notehead>"
                }

                if let staff { xml += "<staff>\(staff)</staff>" }

                if tiedFrom || tiedTo {
                    xml += "<notations>"
                    if tiedFrom { xml += "<tied type=\"stop\"/>" }
                    if tiedTo { xml += "<tied type=\"start\"/>" }
                    xml += "</notations>"
                }

                xml += "</note>\n"
            }

            pieceStart = pieceEnd
        }

        return xml
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
