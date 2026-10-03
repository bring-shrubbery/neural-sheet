import Foundation

/// The chord symbols of the score (chord symbols design §2): a `<harmony>` on the first part
/// written, placed before the piece of its first staff that the chord falls in, with an
/// `<offset>` when it falls inside that piece. Root, kind and bass are spelled as the symbol is,
/// with the suffix as the kind's text so MuseScore and Dorico print what the Score tab prints.
extension MusicXMLWriter {
    /// The harmonies of `chords` that fall in `piece`, each offset from the piece's start.
    static func harmoniesXML(_ chords: ArraySlice<ScoreChord>, in piece: ScorePiece) -> String {
        var xml = ""

        for chord in chords where chord.units >= piece.startUnits && chord.units < piece.startUnits + piece.units {
            xml += harmonyXML(chord, offset: chord.units - piece.startUnits)
        }

        return xml
    }

    /// One `<harmony>`; N.C. is a C root printed as nothing with the kind `none` reading "N.C.",
    /// the form MuseScore writes and reads, since a harmony needs a root.
    static func harmonyXML(_ chord: ScoreChord, offset: Int) -> String {
        var xml = "      <harmony print-frame=\"no\">"

        if let symbol = chord.chord {
            xml += "<root>" + stepXML(symbol.root, flats: chord.flats, element: "root") + "</root>"

            let text = symbol.quality.suffix.replacingOccurrences(of: "♭", with: "b")
            xml += text.isEmpty ? "<kind>" : "<kind text=\"\(escaped(text))\">"
            xml += symbol.quality.musicXMLKind + "</kind>"

            if let bass = symbol.slashBass {
                xml += "<bass>" + stepXML(bass, flats: chord.flats, element: "bass") + "</bass>"
            }
        } else {
            xml += "<root><root-step text=\"\">C</root-step></root>"
            xml += "<kind text=\"\(ChordEvent.noChordText)\">none</kind>"
        }

        if offset != 0 { xml += "<offset>\(offset)</offset>" }

        return xml + "</harmony>\n"
    }

    /// `<root-step>` and `<root-alter>` (or the bass's) for a pitch class spelled as the symbol is.
    private static func stepXML(_ pitchClass: Int, flats: Bool, element: String) -> String {
        let spelled = spelling(midi: 60 + pitchClass, preferFlats: flats)
        var xml = "<\(element)-step>\(spelled.step)</\(element)-step>"

        if spelled.alter != 0 { xml += "<\(element)-alter>\(spelled.alter)</\(element)-alter>" }

        return xml
    }
}
