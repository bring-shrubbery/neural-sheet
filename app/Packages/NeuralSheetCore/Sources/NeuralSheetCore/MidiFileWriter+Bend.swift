import Foundation

/// The notes' pitch curves as pitch bend (pitch curves design §2, MIDI). Bend is per channel,
/// so only a track whose notes never overlap — a monophonic line — can carry it; a track with
/// a chord anywhere gets none, rather than one note's bend detuning the others.
extension MidiFileWriter {
    /// One channel event of an instrument track, with where it sorts among events at its tick.
    struct TrackEvent {
        var tick: Int
        var order: Int
        var bytes: [UInt8]

        // At one tick: the old note's release and recentre, then the new note's opening bend
        // ahead of its strike, so it sounds bent from the start, then any bend inside the note.
        static let noteOff = 0
        static let recentre = 1
        static let leadingBend = 2
        static let noteOn = 3
        static let bend = 4
    }

    /// The bend range RPN 0 sets, in semitones: the curves stay within ±200 cents.
    static let bendRangeSemitones: UInt8 = 2
    /// A bend is written when the curve has moved this far from the last one written, so a
    /// steady note is a handful of events rather than one every 10 ms.
    static let bendStepCents: Float = 5
    static let bendCentre = 8192

    /// Whether no two of `sorted` (in start order) overlap; touching is not overlapping.
    static func isMonophonic(_ sorted: [NoteEvent]) -> Bool {
        var latestEnd = -Double.infinity

        for note in sorted {
            if note.startTime < latestEnd { return false }
            latestEnd = max(latestEnd, note.endTime)
        }

        return true
    }

    /// For a monophonic track with at least one curve: the RPN 0 = ±2 semitones setup for the
    /// track start (each event at delta 0) and the bend events. Otherwise nothing, so a file
    /// without curves is byte for byte what it was.
    static func bends(for sorted: [NoteEvent], channelBits: UInt8,
                      tick: (Double) -> Int) -> (setup: [UInt8], events: [TrackEvent]) {
        guard sorted.contains(where: { !($0.pitchCurve ?? []).isEmpty }), isMonophonic(sorted) else { return ([], []) }

        let control = 0xB0 | channelBits
        // CC 101 / 100: RPN 0 (pitch bend sensitivity); CC 6 / 38: 2 semitones, 0 cents.
        let setup: [UInt8] = [0x00, control, 101, 0, 0x00, control, 100, 0,
                              0x00, control, 6, bendRangeSemitones, 0x00, control, 38, 0]
        var events: [TrackEvent] = []

        for note in sorted {
            guard let curve = note.pitchCurve, !curve.isEmpty else { continue }

            var written: Float = 0

            for (index, raw) in curve.enumerated() {
                let seconds = note.startTime + Double(index) * PitchTracker.frameSeconds

                // A merged note's curve can be shorter than the note, never longer once edited,
                // but a curve is not trusted past the note's end.
                guard seconds < note.endTime else { break }

                // Clamped here as well as in `bendValue`, so the 5 ¢ step is measured on what
                // is written.
                let cents = raw.isFinite ? min(max(raw, -200), 200) : 0

                guard abs(cents - written) >= bendStepCents else { continue }

                events.append(TrackEvent(tick: tick(seconds), order: index == 0 ? TrackEvent.leadingBend : TrackEvent.bend,
                                         bytes: bendEvent(value: bendValue(cents: cents), channelBits: channelBits)))
                written = cents
            }

            if written != 0 {
                events.append(TrackEvent(tick: tick(note.endTime), order: TrackEvent.recentre,
                                         bytes: bendEvent(value: bendCentre, channelBits: channelBits)))
            }
        }

        return (setup, events)
    }

    /// `8192 + cents / 200 × 8191`, the cents clamped to ±200 first, so the range is 1…16383
    /// and symmetric about the centre.
    static func bendValue(cents: Float) -> Int {
        let clamped = cents.isFinite ? min(max(Double(cents), -200), 200) : 0

        return Int((Double(bendCentre) + clamped / 200 * 8191).rounded())
    }

    /// `En lsb msb`: seven bits each, least significant first.
    static func bendEvent(value: Int, channelBits: UInt8) -> [UInt8] {
        [0xE0 | channelBits, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]
    }
}
