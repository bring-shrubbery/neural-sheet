import AppKit
import Foundation
import NeuralSheetCore

/// The words under the notes (markers and lyrics design §2, §4): the lyric card's syllable-at-
/// a-time entry and Paste Lyrics. Every change is an edit through the document, so it undoes
/// with ⌘Z like a pitch or a length.
extension AppModel {
    // MARK: - The lyric card

    /// Edit → Lyric… (⌥L): one note selected in the Edit tab (issue #18, requirement 9).
    var canEnterLyric: Bool { workspace == .edit && canEdit && editor.selection.count == 1 }

    /// Opens the card on the selected note; the timeline shows it anchored there.
    func openLyricEntry() {
        guard canEnterLyric, let id = editor.selection.first else { return }

        editor.lyricNote = id
    }

    /// The card has gone (Escape, a click elsewhere, the last note done): nothing is committed.
    func closeLyricEntry() {
        if editor.lyricNote != nil {
            editor.lyricNote = nil
        }
    }

    /// The previous syllable of the card's note's instrument: what decides whether the one typed
    /// now begins a word or continues it.
    func previousLyric(before id: NoteID) -> Lyric? {
        document?.previousNote(sameProgramAs: id)?.note.lyric
    }

    /// Return or Tab in the card: the typed text read as a syllable (a trailing "-" continues the
    /// word, "_" holds it) committed as one "Lyric" batch, then the card moves to the next note
    /// of the same instrument by start time, selecting it; after the last it closes.
    func commitLyricEntry(_ text: String) {
        guard canEdit, let id = editor.lyricNote, let document, document.contains(id) else {
            closeLyricEntry()
            return
        }

        commit(document.setLyric(id: id, Lyric.typed(text, after: previousLyric(before: id))))

        guard let next = self.document?.nextNote(sameProgramAs: id) else {
            closeLyricEntry()
            return
        }

        setSelection([next.id])
        editor.lyricNote = next.id
    }

    /// The card and inspector field: the one selected note's syllable from its typed form, read
    /// against the syllable before it as the card reads it. Nothing with more than one selected.
    func setSelectedLyric(_ text: String) {
        guard canEdit, editor.selection.count == 1, let id = editor.selection.first, let document else { return }

        commit(document.setLyric(id: id, Lyric.typed(text, after: previousLyric(before: id))))
    }

    // MARK: - Paste Lyrics

    /// Edit → Paste Lyrics…: needs notes to put the words on.
    var canPasteLyrics: Bool { workspace == .edit && canEdit && !(document?.notes.isEmpty ?? true) }

    /// The clipboard's text cut into syllables and handed out in time order to the selection, or
    /// with none selected to every note of the target instrument, as one "Paste Lyrics" edit
    /// (issue #18, requirement 10). Notes past the last syllable stay as they are; syllables past
    /// the last note are dropped, and the dialog says how many.
    func pasteLyrics() {
        guard canPasteLyrics, let document else { return }

        let syllables = LyricSplitter.syllables(from: NSPasteboard.general.string(forType: .string) ?? "")

        guard !syllables.isEmpty else {
            showError("Could not paste lyrics.", "The clipboard holds no text.")
            return
        }

        let targets = editor.selection.isEmpty
            ? document.notes.filter { $0.note.program == editor.targetProgram }
            : document.notes.filter { editor.selection.contains($0.id) }

        guard !targets.isEmpty else {
            showError("Could not paste lyrics.", "The instrument has no notes; select the notes the words go on.")
            return
        }

        // `notes` is in start order already; the selection's order is the document's.
        let (batch, leftOver) = document.setLyrics(targets.map(\.id), lyrics: syllables)
        commit(batch)

        if leftOver > 0 {
            showError("Paste Lyrics", "\(leftOver) \(leftOver == 1 ? "syllable" : "syllables") did not fit; select more notes.")
        }
    }
}
