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

    public init(sourceSampleCount: Int, rawNotes: [NoteEvent], document: NoteDocument) {
        self.sourceSampleCount = sourceSampleCount
        self.rawNotes = rawNotes
        self.document = document
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
