import Foundation
import NeuralSheetCore

/// The chord symbols (chord symbols design §2, §4) as list edits: project state, not note edits,
/// so nothing here makes a batch. Each works on the caller's copy of the list, which the model
/// writes back (and marks hand-edited) when it changed.
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
}
