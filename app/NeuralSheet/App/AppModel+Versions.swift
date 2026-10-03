import Foundation
import NeuralSheetCore

/// Edit → Versions (versions design §2, §4): named snapshots of the notes, saved by hand or
/// before a run replaces them, restored as one undoable edit, and ghosted behind the roll.
///
/// The "Transcription" entry is virtual: `rawNotes`, merged as a fresh document's are, made into
/// a version only when it is restored or compared, so the menu does not merge thousands of notes
/// every time it is rebuilt.
extension AppModel {
    // MARK: - Availability

    /// Saving, comparing and managing: a finished transcription with a document.
    var canUseVersions: Bool { state == .populated && document != nil }

    /// Restoring and Show Differences change the notes or the selection, which only the Edit
    /// tab shows and only its Undo takes back.
    var canRestoreVersion: Bool { canEdit && workspace == .edit }

    var canShowDifferences: Bool { canRestoreVersion && comparedVersion != nil }

    // MARK: - Listing

    /// The menu's and the sheet's rows, the Transcription first: an id, a name, a date (nil for
    /// the Transcription, whose run time is not kept) and a note count. Cheap: no notes are
    /// copied or merged.
    var versionRows: [VersionRow] {
        EditingCommands.versionRows(rawNotes: transcription.rawNotes, versions: versions)
    }

    /// The version with `id`, the Transcription made on demand.
    private func version(id: UUID) -> NoteVersion? {
        EditingCommands.version(id: id, rawNotes: transcription.rawNotes, versions: versions)
    }

    // MARK: - Saving

    /// Save Version… (⌥⌘S): the name asked for in a text alert that says how many notes go in,
    /// offered as "Version N — <date>".
    func saveVersionFromPrompt() {
        guard canUseVersions, let document, let presentText else { return }

        let count = document.notes.count
        presentText(String(localized: "Save Version", comment: "Edit → Versions → Save Version…: the alert's title"),
                    String(localized: "Save the current \(count) notes as a version named:", comment: "Edit → Versions → Save Version…: the alert's question"),
                    defaultVersionName()) { [weak self] name in
            self?.saveVersion(named: name)
        }
    }

    /// "Version 3 — 3 Oct 2026 at 14:02": the next number after the versions there are, and now.
    func defaultVersionName(date: Date = Date()) -> String {
        EditingCommands.defaultVersionName(existing: versions.count, date: date)
    }

    /// The document's notes as a new version, last in the list. A blank name takes the default.
    func saveVersion(named name: String) {
        guard canUseVersions, let document else { return }

        versions.append(EditingCommands.newVersion(named: name, document: document, existing: versions.count))
    }

    /// Before a full or a stems run's notes land (versions design §2): the document's notes, or
    /// those the clear before the run threw away, saved as "Before <run> — 14:02" so a re-run
    /// never loses edits. A region run lands as an undoable batch and does not come here. No
    /// notes, no version: an empty one would say nothing.
    func saveVersionBeforeRun(_ run: String) {
        let notes = document?.events ?? notesBeforeRun
        notesBeforeRun = nil

        guard let version = EditingCommands.versionBeforeRun(run, notes: notes) else { return }

        versions.append(version)
    }

    /// The toolbar's clear, over a document: its notes are kept aside for the run that follows.
    func keepNotesForNextRun() {
        if let document {
            notesBeforeRun = document.events
        }
    }

    // MARK: - Managing

    /// Manage Versions…: the sheet with the table, where versions are renamed and deleted.
    func openManageVersions() {
        guard canUseVersions else { return }

        isManageVersionsPresented = true
    }

    func closeManageVersions() {
        isManageVersionsPresented = false
    }

    /// A new name; blank is refused, and the Transcription keeps its own.
    func renameVersion(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, let index = versions.firstIndex(where: { $0.id == id }),
              versions[index].name != trimmed
        else { return }

        versions[index].name = trimmed

        if comparedVersion?.id == id {
            comparedVersion?.name = trimmed
            refreshComparison()
        }
    }

    /// Gone for good, which is why it is only in Manage Versions…; a compared version stops
    /// being compared. The Transcription cannot be deleted.
    func deleteVersion(id: UUID) {
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return }

        versions.remove(at: index)

        if comparedVersion?.id == id {
            compare(with: nil)
        }
    }

    // MARK: - Restoring

    /// The version's notes in place of the document's, as one edit titled "Restore <name>" that
    /// Undo takes back. The Transcription goes the same way rather than through
    /// ``installDocument(rawNotes:document:)``, so it is undoable; Revert to Transcription keeps
    /// its own path (versions design §2).
    func restoreVersion(id: UUID) {
        guard canRestoreVersion, var document, let version = version(id: id) else { return }

        _ = dragCanceller?()

        let batch = EditingCommands.restore(version, in: &document)
        replaceDocumentAndCommit(document, batch)
    }

    // MARK: - Comparing

    /// Compare With ▸: the version ghosted behind the roll in both tabs, or none.
    func compare(with id: UUID?) {
        guard let id else {
            comparedVersion = nil
            refreshComparison()
            return
        }

        guard canUseVersions, comparedVersion?.id != id, let version = version(id: id) else { return }

        comparedVersion = version
        refreshComparison()
    }

    /// Show Differences: the current notes with no counterpart in the compared version
    /// selected, for review or Delete.
    func showDifferences() {
        guard canShowDifferences, let document, let comparedVersion else { return }

        _ = dragCanceller?()
        setSelection(EditingCommands.differences(in: document, against: comparedVersion))
    }

    /// The status bar's counts, matched again when the document or the comparison changes.
    func refreshComparison() {
        let summary = EditingCommands.comparisonSummary(document: document, comparedVersion: comparedVersion)

        if summary != comparisonSummary {
            comparisonSummary = summary
        }
    }
}
