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
                showError(String(localized: "Could not detect chords.", comment: "Alert title: Edit → Detect Chords failed"),
                          String(localized: "The transcription has no melodic notes.", comment: "Alert body: only drums, so no chords"))
            }
            return
        }

        guard editor.chordsEdited, !editor.chords.isEmpty, let presentConfirm else {
            runChordDetection()
            return
        }

        presentConfirm(String(localized: "Replace the chord symbols?", comment: "Alert title: Detect Chords over edited chords"),
                       String(localized: "Detect replaces the chord symbols you have edited with what it finds in the notes.",
                              comment: "Alert body: Detect Chords over edited chords"),
                       String(localized: "Replace", comment: "Alert button: replace the edited chords")) { [weak self] confirmed in
            if confirmed {
                self?.runChordDetection()
            }
        }
    }

    /// On the main actor: one profile per bar and half bar is quick, even over a long take.
    private func runChordDetection() {
        guard let document else { return }

        let found = EditingCommands.detectedChords(in: document, editor: editor, duration: duration)

        if editor.chords != found { editor.chords = found }
        if editor.chordsEdited { editor.chordsEdited = false }
    }

    // MARK: - Editing

    /// A chord at `seconds`: the one sounding there again, or the key's tonic triad, or C. The
    /// lane picks the spot (the nearest beat or grid line). Answers the new chord's index; one
    /// already at that spot is answered instead of doubled.
    @discardableResult
    func addChord(at seconds: Double) -> Int? {
        guard document != nil else { return nil }

        var list = editor.chords

        guard let added = EditingCommands.addChord(&list, at: seconds, key: editor.key) else { return nil }

        if added.inserted {
            editChords { $0 = list }
        }

        return added.index
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
        var list = editor.chords

        guard let landing = EditingCommands.moveChord(&list, from: index, to: seconds) else { return nil }

        if list != editor.chords {
            editChords { $0 = list }
        }

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
