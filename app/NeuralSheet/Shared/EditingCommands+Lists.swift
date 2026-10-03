import Foundation
import NeuralSheetCore

/// The chord symbols (chord symbols design §2, §4) and the section markers (markers and lyrics
/// design §2, §4) as list edits: project state, not note edits, so nothing here makes a batch.
/// Each works on the caller's copy of the list, which the model writes back when it changed.
nonisolated extension EditingCommands {
    // MARK: - Chords

    /// Detect: the chords the melodic notes say, over the take or the notes, whichever is
    /// longer. Quick enough for the main actor: one profile per bar and half bar.
    static func detectedChords(in document: NoteDocument, editor: EditorState, duration: Double) -> [ChordEvent] {
        let notesEnd = document.events.map(\.endTime).max() ?? 0

        return ChordDetector.detect(notes: document.events, grid: editor.grid, key: editor.key,
                                    duration: max(duration, notesEnd))
    }

    /// A chord at `seconds`: the one sounding there again, or the key's tonic triad, or C.
    /// Answers its index and whether it was inserted; one already at that spot is answered
    /// instead of doubled. Nil for a time that is not finite.
    static func addChord(_ chords: inout [ChordEvent], at seconds: Double, key: MusicalKey?) -> (index: Int, inserted: Bool)? {
        guard seconds.isFinite else { return nil }

        let seconds = max(0, seconds)

        if let existing = chords.firstIndex(where: { abs($0.seconds - seconds) < 0.001 }) {
            return (existing, false)
        }

        let sounding = chords.chordIndex(at: seconds).flatMap { chords[$0].chord }
        let fallback = key.map { ChordSymbol(root: $0.tonic, quality: $0.mode == .minor ? .minor : .major) }
        let chord = sounding ?? fallback ?? ChordSymbol(root: 0, quality: .major)

        let index = chords.firstIndex { $0.seconds > seconds } ?? chords.count
        chords.insert(ChordEvent(seconds: seconds, chord: chord), at: index)

        return (index, true)
    }

    /// A drag in the lane: the chord at `index` to `seconds`, the list kept in order. Answers
    /// where it landed; landing on another chord's spot replaces that one. Nil for an index or a
    /// time out of range.
    static func moveChord(_ chords: inout [ChordEvent], from index: Int, to seconds: Double) -> Int? {
        guard chords.indices.contains(index), seconds.isFinite else { return nil }

        let seconds = max(0, seconds)
        var event = chords[index]

        guard event.seconds != seconds else { return index }

        event.seconds = seconds
        chords.remove(at: index)
        chords.removeAll { abs($0.seconds - seconds) < 0.001 }

        let landing = chords.firstIndex { $0.seconds > seconds } ?? chords.count
        chords.insert(event, at: landing)

        return landing
    }

    // MARK: - Markers

    /// A marker at `seconds` (inside the take) named "Marker N", the list kept in order. Answers
    /// its id and whether it was added; one already at that spot is answered instead of doubled.
    /// Nil for a time that is not finite.
    static func addMarker(_ markers: inout [Marker], at seconds: Double, duration: Double) -> (id: UUID, inserted: Bool)? {
        guard seconds.isFinite else { return nil }

        let seconds = min(max(0, seconds), max(duration, 0))

        if let existing = markers.first(where: { abs($0.seconds - seconds) < 0.001 }) {
            return (existing.id, false)
        }

        let marker = Marker(seconds: seconds, name: markers.nextDefaultName())
        markers = (markers + [marker]).sortedMarkers()

        return (marker.id, true)
    }

    /// A drag on the ruler: the marker to `seconds` inside the take, the list kept in order.
    /// False when nothing moved.
    static func moveMarker(_ markers: inout [Marker], id: UUID, to seconds: Double, duration: Double) -> Bool {
        guard seconds.isFinite, let index = markers.firstIndex(where: { $0.id == id }) else { return false }

        let seconds = min(max(0, seconds), max(duration, 0))

        guard markers[index].seconds != seconds else { return false }

        markers[index].seconds = seconds
        markers = markers.sortedMarkers()

        return true
    }

    /// A double-click on a flag: the range from the marker to the next one, or to the end of the
    /// take; nil for a marker that is not there.
    static func section(from id: UUID, in markers: [Marker], duration: Double) -> Range<Double>? {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return nil }

        let start = markers[index].seconds
        let end = markers[(index + 1)...].first { $0.seconds > start }?.seconds ?? duration

        return start ..< max(start, end)
    }
}
