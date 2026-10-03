import Foundation
import NeuralSheetCore

/// What the status bar says while a version is compared (versions design §2, Differences).
nonisolated struct VersionComparisonSummary: Equatable {
    var added: Int
    var missing: Int
    var name: String
}

/// A row of Edit → Versions and of the sheet that manages them: an id, a name, a date (nil for
/// the Transcription, whose run time is not kept) and a note count.
nonisolated struct VersionRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let date: Date?
    let noteCount: Int

    var isTranscription: Bool { id == NoteVersion.transcriptionID }

    /// "small — 412 notes", the menu item's title (versions design §2).
    var menuTitle: String {
        String(localized: "\(name) — \(noteCount) notes", comment: "Edit → Versions: a version and its note count, e.g. \"Version 2 — 412 notes\"")
    }
}

/// Edit → Versions (versions design §2, §4): the listing, the names, the restore batch and the
/// comparison, from the model's raw notes, versions and document.
///
/// The "Transcription" entry is virtual: the raw notes, merged as a fresh document's are, made
/// into a version only when it is restored or compared, so the menu does not merge thousands of
/// notes every time it is rebuilt.
nonisolated extension EditingCommands {
    // MARK: - Listing

    /// The rows, the Transcription first. Cheap: no notes are copied or merged.
    static func versionRows(rawNotes: [NoteEvent], versions: [NoteVersion]) -> [VersionRow] {
        [VersionRow(id: NoteVersion.transcriptionID, name: CoreNames.localized(NoteVersion.transcriptionName), date: nil,
                    noteCount: rawNotes.count)]
            + versions.map { VersionRow(id: $0.id, name: $0.name, date: $0.date, noteCount: $0.notes.count) }
    }

    /// The version with `id`, the Transcription made on demand.
    static func version(id: UUID, rawNotes: [NoteEvent], versions: [NoteVersion]) -> NoteVersion? {
        id == NoteVersion.transcriptionID
            ? NoteVersion.transcription(rawNotes: rawNotes)
            : versions.first { $0.id == id }
    }

    // MARK: - Saving

    /// "Version 3 — 3 Oct 2026 at 14:02": the next number after the `existing` versions, and
    /// `date`.
    static func defaultVersionName(existing: Int, date: Date = Date()) -> String {
        let number = existing + 1
        let when = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)

        return String(localized: "Version \(number) — \(when)", comment: "A version's default name, its number and when it was saved")
    }

    /// The document's notes as a version named `name`; a blank name takes the default.
    static func newVersion(named name: String, document: NoteDocument, existing: Int) -> NoteVersion {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        return NoteVersion(name: trimmed.isEmpty ? defaultVersionName(existing: existing) : trimmed, notes: document.events)
    }

    /// Before a full or a stems run's notes land: `notes` saved as "Before <run> — 14:02" so a
    /// re-run never loses edits. No notes, no version: an empty one would say nothing.
    static func versionBeforeRun(_ run: String, notes: [NoteEvent]?) -> NoteVersion? {
        guard let notes, !notes.isEmpty else { return nil }

        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)

        return NoteVersion(name: String(localized: "Before \(run) — \(time)", comment: "A version saved before a run, e.g. \"Before Transcribe — 14:02\""),
                           notes: notes)
    }

    // MARK: - Restoring

    /// The version's notes in place of the document's, as one edit titled "Restore <name>".
    /// Allocates ids, so it runs on the caller's copy, which is the one to commit on.
    static func restore(_ version: NoteVersion, in document: inout NoteDocument) -> EditBatch {
        document.replaceAll(with: version.notes, title: String(localized: "Restore \(version.name)", comment: "Undo title: a version restored"))
    }

    // MARK: - Comparing

    /// Show Differences: the current notes with no counterpart in the compared version.
    static func differences(in document: NoteDocument, against version: NoteVersion) -> Set<NoteID> {
        NoteMatcher.unmatched(current: document.notes, against: version.notes).added
    }

    /// The status bar's counts while `version` is compared; nil with no comparison.
    static func comparisonSummary(document: NoteDocument?, comparedVersion version: NoteVersion?) -> VersionComparisonSummary? {
        guard let version, let document else { return nil }

        let result = NoteMatcher.unmatched(current: document.notes, against: version.notes)

        return VersionComparisonSummary(added: result.added.count, missing: result.missing.count,
                                        name: CoreNames.localized(version.name))
    }
}
