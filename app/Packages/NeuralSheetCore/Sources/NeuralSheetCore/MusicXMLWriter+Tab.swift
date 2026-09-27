import Foundation

/// The tab parts of the score (arrangement design §5): a TAB clef, the staff's lines and
/// tuning, and each note's sounding pitch with its string and fret. MusicXML numbers the strings
/// from the top (1 is the highest line); the tab staff numbers them from the bottom.
extension MusicXMLWriter {
    /// One `<part>` for a part's tab staff, the same measures as its notation.
    static func tabPartXML(_ tab: ScoreTabStaff, id: String, fifths: Int, grid: TempoGrid, writesTempo: Bool) -> String {
        var xml = "  <part id=\"\(id)\">\n"

        for (measureIndex, measure) in tab.measures.enumerated() {
            xml += "    <measure number=\"\(measureIndex + 1)\">\n"

            if measureIndex == 0 {
                xml += "      <attributes>\n"
                xml += "        <divisions>\(divisions)</divisions>\n"
                xml += "        <key><fifths>\(fifths)</fifths></key>\n"
                xml += "        <time><beats>\(TempoGrid.beatsPerBar)</beats><beat-type>4</beat-type></time>\n"
                xml += "        <clef><sign>TAB</sign><line>5</line></clef>\n"
                xml += staffDetailsXML(tuning: tab.tuning)
                xml += "      </attributes>\n"

                if writesTempo { xml += tempoXML(grid: grid) }
            }

            for piece in measure.pieces {
                xml += tabPieceXML(piece, stringCount: tab.tuning.count)
            }

            xml += "    </measure>\n"
        }

        xml += "  </part>\n"

        return xml
    }

    /// The staff's line count and one `<staff-tuning>` per string, line 1 the bottom, the
    /// open pitches spelled in sharps.
    static func staffDetailsXML(tuning: [Int]) -> String {
        var xml = "        <staff-details><staff-lines>\(tuning.count)</staff-lines>"

        for (index, pitch) in tuning.enumerated() {
            let spelled = spelling(midi: pitch, preferFlats: false)

            xml += "<staff-tuning line=\"\(index + 1)\"><tuning-step>\(spelled.step)</tuning-step>"
            if spelled.alter != 0 { xml += "<tuning-alter>\(spelled.alter)</tuning-alter>" }
            xml += "<tuning-octave>\(spelled.octave)</tuning-octave></staff-tuning>"
        }

        return xml + "</staff-details>\n"
    }

    /// One piece of the tab staff: a rest as the notation's, or a chord of sounding pitches each
    /// with its string and fret.
    private static func tabPieceXML(_ piece: ScorePiece, stringCount: Int) -> String {
        guard !piece.isRest else { return restXML(piece, voice: 1, staff: nil) }

        var xml = ""

        for (index, note) in piece.notes.enumerated() {
            var technical = ""

            if let placement = note.placement {
                technical = "<technical><string>\(stringCount - placement.string)</string><fret>\(placement.fret)</fret></technical>"
            }

            xml += noteXML(piece, note: note, isChord: index > 0, pitch: pitchXML(note.pitch, preferFlats: false),
                           voice: 1, staff: nil, notehead: nil, technical: technical)
        }

        return xml
    }
}
