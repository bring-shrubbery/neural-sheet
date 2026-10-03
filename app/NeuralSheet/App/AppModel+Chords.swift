import Foundation
import NeuralSheetCore

/// The chord symbols (chord symbols design §2, §4): a list in seconds on the editor, filled by
/// Detect from the melodic notes and corrected by hand in the Edit tab's lane. Like the key, the
/// list is project state, not a note edit: nothing here goes on the undo stack, and any change
/// marks the project edited (`ProjectContent.chords`).
extension AppModel {
    var chords: [ChordEvent] { editor.chords }

    /// Whether there are melodic notes to read chords from.
    var canDetectChords: Bool {
        document?.events.contains { !$0.isDrum } ?? false
    }

    // MARK: - Detect

    /// Edit → Detect Chords, and the Detect button after the key: the whole list replaced by
    /// what the notes say, after asking when the user has corrected the one there. From the menu
    /// a transcription with nothing to read is said so; after the tempo it is left quietly.
    func detectChords(reportsNothing: Bool = true) {
        guard canDetectChords else {
            if reportsNothing, document != nil {
                showError("Could not detect chords.", "The transcription has no melodic notes.")
            }
            return
        }

        guard editor.chordsEdited, !editor.chords.isEmpty, let presentConfirm else {
            runChordDetection()
            return
        }

        presentConfirm("Replace the chord symbols?",
                       "Detect replaces the chord symbols you have edited with what it finds in the notes.",
                       "Replace") { [weak self] confirmed in
            if confirmed {
                self?.runChordDetection()
            }
        }
    }

    /// On the main actor: one profile per bar and half bar is quick, even over a long take.
    private func runChordDetection() {
        guard let document else { return }

        let notesEnd = document.events.map(\.endTime).max() ?? 0
        let found = ChordDetector.detect(notes: document.events, grid: editor.grid, key: editor.key,
                                         duration: max(duration, notesEnd))

        if editor.chords != found { editor.chords = found }
        if editor.chordsEdited { editor.chordsEdited = false }
    }

    // MARK: - Editing

    /// A chord at `seconds`: the one sounding there again, or the key's tonic triad, or C. The
    /// lane picks the spot (the nearest beat or grid line). Answers the new chord's index; one
    /// already at that spot is answered instead of doubled.
    @discardableResult
    func addChord(at seconds: Double) -> Int? {
        guard document != nil, seconds.isFinite else { return nil }

        let seconds = max(0, seconds)

        if let existing = editor.chords.firstIndex(where: { abs($0.seconds - seconds) < 0.001 }) {
            return existing
        }

        let sounding = editor.chords.chordIndex(at: seconds).flatMap { editor.chords[$0].chord }
        let fallback = editor.key.map { ChordSymbol(root: $0.tonic, quality: $0.mode == .minor ? .minor : .major) }
        let chord = sounding ?? fallback ?? ChordSymbol(root: 0, quality: .major)

        let index = editor.chords.firstIndex { $0.seconds > seconds } ?? editor.chords.count
        editChords { $0.insert(ChordEvent(seconds: seconds, chord: chord), at: index) }

        return index
    }

    /// The card's menus: the chord at `index` becomes `chord`, nil for N.C.
    func setChord(at index: Int, _ chord: ChordSymbol?) {
        guard editor.chords.indices.contains(index), editor.chords[index].chord != chord else { return }

        editChords { $0[index].chord = chord }
    }

    /// The card's Delete.
    func removeChord(at index: Int) {
        guard editor.chords.indices.contains(index) else { return }

        editChords { $0.remove(at: index) }
    }

    /// A drag in the lane: the chord at `index` to `seconds`, the list kept in order. Answers
    /// where it landed; landing on another chord's spot replaces that one.
    @discardableResult
    func moveChord(from index: Int, to seconds: Double) -> Int? {
        guard editor.chords.indices.contains(index), seconds.isFinite else { return nil }

        let seconds = max(0, seconds)
        var event = editor.chords[index]

        guard event.seconds != seconds else { return index }

        event.seconds = seconds

        var list = editor.chords
        list.remove(at: index)
        list.removeAll { abs($0.seconds - seconds) < 0.001 }

        let landing = list.firstIndex { $0.seconds > seconds } ?? list.count
        list.insert(event, at: landing)
        editChords { $0 = list }

        return landing
    }

    /// Every hand edit goes through here, so Detect knows to ask next time.
    private func editChords(_ change: (inout [ChordEvent]) -> Void) {
        var list = editor.chords
        change(&list)
        editor.chords = list

        if !editor.chordsEdited { editor.chordsEdited = true }
    }
}
