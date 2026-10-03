import Foundation

/// The notation parts of the score (arrangement design §5): a part's measures from the score
/// document, its clef or clefs, its written key and its transposition, and the notes, rests,
/// ties and chords of each measure.
extension MusicXMLWriter {
    /// One `<part>`: the attributes on the first measure and the meter wherever it changes, then
    /// every staff of every measure, a `<backup>` of the measure's length between the staves of a
    /// grand staff. The first part written carries the tempo marks and the `chords`.
    static func notationPartXML(_ part: ScorePart, id: String, bars: [ScoreBar], writesTempo: Bool,
                                chords: [ScoreChord] = []) -> String {
        let isDrums = part.program == NoteEvent.drumProgram
        let preferFlats = part.writtenFifths < 0
        let measureCount = part.staves.first?.measures.count ?? 0
        // An octave clef shifts where a reader draws a `<pitch>` by itself, so its octave is taken
        // out of both the pitches and the `<transpose>`: a guitar written +12 on a treble 8vb staff
        // gets the clef and its sounding pitches, and no `<transpose>` to stack a second octave on.
        let clefOctave = part.staves.contains { $0.clef.isOctaveDown } ? 12 : 0
        var xml = "  <part id=\"\(id)\">\n"

        for measureIndex in 0..<measureCount {
            xml += "    <measure number=\"\(measureIndex + 1)\">\n"

            if measureIndex == 0 {
                xml += "      <attributes>\n"
                xml += "        <divisions>\(divisions)</divisions>\n"
                xml += "        <key><fifths>\(part.writtenFifths)</fifths></key>\n"
                xml += "        \(timeXML(bars[measureIndex].timeSignature))\n"

                if part.staves.count > 1 {
                    xml += "        <staves>\(part.staves.count)</staves>\n"
                }

                for (staffIndex, staff) in part.staves.enumerated() {
                    xml += "        " + clefXML(staff.clef, number: part.staves.count > 1 ? staffIndex + 1 : nil) + "\n"
                }

                let transpose = transposeXML(isDrums ? 0 : part.display.transposition - clefOctave)
                if !transpose.isEmpty { xml += "        \(transpose)\n" }

                xml += "      </attributes>\n"
            } else if bars[measureIndex].showsTimeSignature {
                xml += meterChangeXML(bars[measureIndex].timeSignature)
            }

            if writesTempo, bars[measureIndex].showsTempo { xml += tempoXML(bars[measureIndex]) }

            for (staffIndex, staff) in part.staves.enumerated() where measureIndex < staff.measures.count {
                if staffIndex > 0 {
                    xml += "      <backup><duration>\(bars[measureIndex].lengthUnits)</duration></backup>\n"
                }

                let staffNumber = part.staves.count > 1 ? staffIndex + 1 : nil
                let pitchShift = staff.clef.isOctaveDown ? -12 : 0

                for piece in staff.measures[measureIndex].pieces {
                    if staffIndex == 0 { xml += harmoniesXML(chords.inMeasure(measureIndex), in: piece) }
                    xml += pieceXML(piece, voice: staffIndex + 1, staff: staffNumber, isDrums: isDrums,
                                    preferFlats: preferFlats, pitchShift: pitchShift)
                }
            }

            xml += "    </measure>\n"
        }

        xml += "  </part>\n"

        return xml
    }

    // MARK: - Attributes

    /// The clef's sign and line; the octave clefs their parent's with `<clef-octave-change>`.
    static func clefXML(_ clef: Clef, number: Int?) -> String {
        let open = number.map { "<clef number=\"\($0)\">" } ?? "<clef>"

        switch clef {
        case .treble: return "\(open)<sign>G</sign><line>2</line></clef>"
        case .bass: return "\(open)<sign>F</sign><line>4</line></clef>"
        case .alto: return "\(open)<sign>C</sign><line>3</line></clef>"
        case .tenor: return "\(open)<sign>C</sign><line>4</line></clef>"
        case .treble8vb: return "\(open)<sign>G</sign><line>2</line><clef-octave-change>-1</clef-octave-change></clef>"
        case .bass8vb: return "\(open)<sign>F</sign><line>4</line><clef-octave-change>-1</clef-octave-change></clef>"
        case .percussion: return "\(open)<sign>percussion</sign><line>2</line></clef>"
        }
    }

    /// `<transpose>` for a part written `transposition` semitones above its sound: MusicXML's
    /// chromatic is sounding minus written, the whole octaves as `<octave-change>`. Empty for
    /// a part at pitch.
    static func transposeXML(_ transposition: Int) -> String {
        guard transposition != 0 else { return "" }

        let chromatic = -(transposition % 12)
        let octaves = -transposition / 12
        var xml = "<transpose><chromatic>\(chromatic)</chromatic>"

        if octaves != 0 { xml += "<octave-change>\(octaves)</octave-change>" }

        return xml + "</transpose>"
    }

    static func timeXML(_ meter: TimeSignature) -> String {
        "<time><beats>\(meter.numerator)</beats><beat-type>\(meter.denominator)</beat-type></time>"
    }

    /// The meter alone, for a measure after the first where it changes.
    static func meterChangeXML(_ meter: TimeSignature) -> String {
        "      <attributes>\n        \(timeXML(meter))\n      </attributes>\n"
    }

    /// The metronome mark in the unit the meter is felt in (a dotted quarter in 6/8) and the
    /// quarter-note tempo a player sets, at a tempo to a tenth.
    static func tempoXML(_ bar: ScoreBar) -> String {
        let bpm = TempoGrid.clampedBpm(bar.bpm)
        let unit = bar.timeSignature.metronomeUnit
        var xml = "      <direction placement=\"above\"><direction-type><metronome><beat-unit>\(unit.type)</beat-unit>"
        if unit.dotted { xml += "<beat-unit-dot/>" }
        xml += "<per-minute>\(tempoText(bpm / unit.quarters))</per-minute></metronome></direction-type>"
        xml += "<sound tempo=\"\(tempoText(bpm))\"/></direction>\n"

        return xml
    }

    /// "120", or "92.5" for a tempo between whole numbers.
    public static func tempoText(_ bpm: Double) -> String {
        let tenths = (bpm * 10).rounded() / 10

        return tenths == tenths.rounded() ? "\(Int(tenths))" : "\(tenths)"
    }

    // MARK: - Notes and rests

    /// A rest of the piece's value, or a whole-measure rest.
    static func restXML(_ piece: ScorePiece, voice: Int, staff: Int?) -> String {
        var xml = "      <note>"

        if piece.isWholeMeasureRest {
            xml += "<rest measure=\"yes\"/><duration>\(piece.units)</duration><voice>\(voice)</voice>"
        } else {
            xml += "<rest/><duration>\(piece.units)</duration><voice>\(voice)</voice><type>\(piece.type)</type>"
            xml += String(repeating: "<dot/>", count: piece.dots)
        }

        xml += staff.map { "<staff>\($0)</staff>" } ?? ""

        return xml + "</note>\n"
    }

    /// One piece of a notation staff: a rest, or a chord of written pitches (`pitchShift` semitones
    /// off them, the octave an octave clef carries by itself), the drums unpitched at their staff
    /// positions.
    private static func pieceXML(_ piece: ScorePiece, voice: Int, staff: Int?, isDrums: Bool, preferFlats: Bool,
                                 pitchShift: Int) -> String {
        guard !piece.isRest else { return restXML(piece, voice: voice, staff: staff) }

        var xml = ""

        for (index, note) in piece.notes.enumerated() {
            let pitch: String
            let notehead: String?

            if isDrums {
                let display = drumDisplay(note: note.writtenPitch)
                pitch = "<unpitched><display-step>\(display.step)</display-step><display-octave>\(display.octave)</display-octave></unpitched>"
                notehead = display.notehead
            } else {
                pitch = pitchXML(note.writtenPitch + pitchShift, preferFlats: preferFlats)
                notehead = nil
            }

            xml += noteXML(piece, note: note, isChord: index > 0, pitch: pitch, voice: voice, staff: staff,
                           notehead: notehead, technical: "")
        }

        return xml
    }

    static func pitchXML(_ midi: Int, preferFlats: Bool) -> String {
        let spelled = spelling(midi: midi, preferFlats: preferFlats)
        var xml = "<pitch><step>\(spelled.step)</step>"

        if spelled.alter != 0 { xml += "<alter>\(spelled.alter)</alter>" }

        return xml + "<octave>\(spelled.octave)</octave></pitch>"
    }

    /// One `<note>` of a chord: its pitch element, value, ties, dots, head, staff, and
    /// `<notations>` holding the ties and `technical` (the tab's string and fret) when any.
    static func noteXML(_ piece: ScorePiece, note: ScoreNote, isChord: Bool, pitch: String, voice: Int, staff: Int?,
                        notehead: String?, technical: String) -> String {
        var xml = "      <note>"

        if isChord { xml += "<chord/>" }
        xml += pitch
        xml += "<duration>\(piece.units)</duration>"
        if note.tiedFrom { xml += "<tie type=\"stop\"/>" }
        if note.tiedTo { xml += "<tie type=\"start\"/>" }
        xml += "<voice>\(voice)</voice><type>\(piece.type)</type>"
        xml += String(repeating: "<dot/>", count: piece.dots)
        if let notehead { xml += "<notehead>\(notehead)</notehead>" }
        if let staff { xml += "<staff>\(staff)</staff>" }

        if note.tiedFrom || note.tiedTo || !technical.isEmpty {
            xml += "<notations>"
            if note.tiedFrom { xml += "<tied type=\"stop\"/>" }
            if note.tiedTo { xml += "<tied type=\"start\"/>" }
            xml += technical
            xml += "</notations>"
        }

        return xml + "</note>\n"
    }
}
