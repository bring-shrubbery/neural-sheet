import Foundation

/// The words in the MIDI file (markers and lyrics design §2): a marker meta event (`FF 06`) in
/// the conductor track per section marker, and a lyric meta event (`FF 05`) at each syllable's
/// onset on its instrument's track, the text as typed with a trailing "-" on a syllable whose
/// word continues, so karaoke players join it to the next.
extension MidiFileWriter {
    /// `FF type len text`: a text-class meta event, the text in UTF-8.
    static func textEvent(type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)

        return [0xFF, type] + vlq(bytes.count) + bytes
    }

    /// The conductor's events with a marker event per named marker merged in, in tick order; at
    /// one tick a marker follows the tempo and meter already there.
    static func withMarkers(_ meta: [(tick: Int, bytes: [UInt8])], _ markers: [Marker],
                            tick: (Double) -> Int) -> [(tick: Int, bytes: [UInt8])] {
        let events = markers.sortedMarkers().compactMap { marker -> (tick: Int, bytes: [UInt8])? in
            let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)

            return name.isEmpty ? nil : (tick(marker.seconds), textEvent(type: 0x06, name))
        }

        guard !events.isEmpty else { return meta }

        return (meta + events).enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)
    }

    /// One lyric event per note with a syllable, at the note's tick.
    static func lyricEvents(for notes: [NoteEvent], tick: (Double) -> Int) -> [TrackEvent] {
        notes.compactMap { note in
            guard let lyric = note.lyric else { return nil }

            return TrackEvent(tick: tick(note.startTime), order: TrackEvent.lyric, bytes: textEvent(type: 0x05, lyric.midiText))
        }
    }
}
