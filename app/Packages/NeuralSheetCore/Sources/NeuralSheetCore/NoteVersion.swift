import Foundation

/// A named snapshot of the notes (versions design §2): what Edit → Versions saves, restores and
/// ghosts behind the roll. Notes only — the document's events with their confidence, curves and
/// lyrics — since a version is a guess at the notes, not at the grid, the key or the arrangement.
///
/// No ids: a restore inserts the notes afresh, so the ids a snapshot was taken with would mean
/// nothing to the document it lands in.
public struct NoteVersion: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var date: Date
    public var notes: [NoteEvent]

    public init(id: UUID = UUID(), name: String, date: Date = Date(), notes: [NoteEvent]) {
        self.id = id
        self.name = name
        self.date = date
        self.notes = notes
    }

    /// The id of the virtual "Transcription" entry: the model's own output, listed first and
    /// never stored as a version, since `rawNotes` already holds it (versions design §2).
    public static let transcriptionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// What the virtual entry is called; the same words as Revert to Transcription.
    public static let transcriptionName = "Transcription"

    /// The model's own output as a version: merged as a fresh document's notes are, so a
    /// restore or a comparison sees what Revert to Transcription would give. `date` is when it
    /// is asked for: the run's own time is not kept.
    public static func transcription(rawNotes: [NoteEvent], date: Date = Date()) -> NoteVersion {
        NoteVersion(id: transcriptionID, name: transcriptionName, date: date,
                    notes: mergeOverlappingNotesWithSamePitch(rawNotes))
    }

    /// Whether this is the virtual entry, which cannot be renamed or deleted.
    public var isTranscription: Bool { id == NoteVersion.transcriptionID }
}
