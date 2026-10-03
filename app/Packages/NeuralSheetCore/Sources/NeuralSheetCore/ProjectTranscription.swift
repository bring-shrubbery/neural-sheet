import Foundation

/// The transcription as the project keeps it: the model's own output, the edited document, and the
/// sample count of the audio it belongs to — a package whose audio decodes to another length gets no
/// notes rather than notes against the wrong audio.
///
/// Its own file inside the package (`transcription.json`), written compact: it is megabytes for a
/// long take.
public struct ProjectTranscription: Codable, Equatable, Sendable {
    public var sourceSampleCount: Int
    public var rawNotes: [NoteEvent]
    public var document: NoteDocument
    /// The saved versions of the notes, oldest first (versions design §2). Not the "Transcription"
    /// entry, which is `rawNotes` presented as one. Additive: a file from before versions has no
    /// key and reads back empty, and an empty list writes no key.
    public var versions: [NoteVersion]

    public init(sourceSampleCount: Int, rawNotes: [NoteEvent], document: NoteDocument, versions: [NoteVersion] = []) {
        self.sourceSampleCount = sourceSampleCount
        self.rawNotes = rawNotes
        self.document = document
        self.versions = versions
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case sourceSampleCount, rawNotes, document, versions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSampleCount = try container.decode(Int.self, forKey: .sourceSampleCount)
        rawNotes = try container.decode([NoteEvent].self, forKey: .rawNotes)
        document = try container.decode(NoteDocument.self, forKey: .document)
        versions = try container.decodeIfPresent([NoteVersion].self, forKey: .versions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceSampleCount, forKey: .sourceSampleCount)
        try container.encode(rawNotes, forKey: .rawNotes)
        try container.encode(document, forKey: .document)

        if !versions.isEmpty {
            try container.encode(versions, forKey: .versions)
        }
    }

    // MARK: - Equatable

    /// Two transcriptions are the same when their notes are: `sourceSampleCount`, `rawNotes`,
    /// `document.notes` and the versions (a saved, renamed or deleted version is a change to the
    /// project, versions design §2).
    ///
    /// Hand-written because the synthesized `==` would reach into ``NoteDocument``'s undo and redo
    /// stacks and its id allocator, none of which say anything about what the user would lose. The
    /// project's dirty rule compares this with the value taken at the last save, so an edit
    /// followed by an undo -- which leaves the notes exactly where they were, and the history one
    /// batch longer -- would keep the dot in the close button for ever.
    ///
    /// `document.isEdited` is left out for the same reason although the file encodes it: it is
    /// sticky (set by the first commit, never cleared by an undo back to the start), so an edit
    /// undone on a document that was saved clean would still read as edited.
    public static func == (lhs: ProjectTranscription, rhs: ProjectTranscription) -> Bool {
        lhs.sourceSampleCount == rhs.sourceSampleCount
            && lhs.rawNotes == rhs.rawNotes
            && lhs.document.notes == rhs.document.notes
            && lhs.versions == rhs.versions
    }

    // MARK: - Files

    /// The transcription at `url`, or nil if there is no file, it cannot be read, or it is not JSON
    /// this version understands: the audio and the settings around it survive.
    public static func load(from url: URL) -> ProjectTranscription? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        return try? JSONDecoder().decode(ProjectTranscription.self, from: data)
    }

    /// Writes the transcription as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
