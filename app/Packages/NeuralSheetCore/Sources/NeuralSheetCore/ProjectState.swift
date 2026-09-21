import Foundation

/// The transcription as the session keeps it: the model's own output, the edited document, and
/// the sample count of the audio it belongs to — a reloaded file of another length gets no notes.
///
/// Its own file (`AppPaths.transcription`), written compact: it is megabytes for a long take and
/// changes only when an edit lands, where the session changes with every playhead move.
public struct SessionTranscription: Codable, Equatable, Sendable {
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
    /// this version understands.
    public static func load(from url: URL) -> SessionTranscription? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        return try? JSONDecoder().decode(SessionTranscription.self, from: data)
    }

    /// Writes the transcription as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// What went wrong opening or saving a project; the app turns each case into the dialog's body.
public enum ProjectError: Error, Equatable, Sendable {
    /// Not a `.neuralsheet` directory holding a `project.json`.
    case notAPackage
    /// `project.json` exists but does not decode; the description says why.
    case unreadable(String)
    /// Written by a version of NeuralSheet with a greater format version than this one's.
    case newerVersion(Int)
    /// `project.json` names an audio file that is not in `audio/`.
    case missingAudio
    /// The package could not be written; the description is the file system's.
    case couldNotWrite(String)
}

/// One project's settings and view state: what `project.json` holds. The audio is a file beside it
/// (`audioFileName`, inside `audio/`) and the transcription a file of its own
/// (``ProjectTranscription``).
///
/// Stored as JSON with sorted keys and indentation so two saves of the same state give the same
/// bytes and the file stays readable by hand. A key that is not there falls back to its default, so a
/// file from an older version still opens; the one thing that refuses is a `formatVersion` greater
/// than ``currentFormatVersion``, since a newer app may have written something this one would
/// silently drop on the next save.
public struct ProjectState: Codable, Equatable, Sendable {
    /// Bump when a change would make an older app misread the file.
    public static let currentFormatVersion = 1

    public var formatVersion = ProjectState.currentFormatVersion
    /// The audio's file name inside `audio/`; empty when the project has no audio.
    public var audioFileName = ""
    /// What the toolbar shows and the MIDI export is named after; nil for a recording.
    public var audioDisplayName: String? = nil
    /// `InstrumentGroup` raw values, in enumerator order. Empty means automatic.
    public var selectedGroups: [Int32] = []
    /// The mix, keyed by program; an absent program is `InstrumentChannelSettings()`.
    public var mixer: [Int: InstrumentChannelSettings] = [:]
    public var exportTempo: Double = 120
    public var gridOffsetSeconds: Double = 0
    public var gridDivision: GridDivision = .sixteenth
    public var snapEnabled = true
    /// The instrument new and reassigned notes go to; nil means the first strip.
    public var targetProgram: Int? = nil

    // View state: written on every save, never what makes the project edited.

    public var workspace: Workspace = .transcribe
    public var playheadSeconds: Double = 0
    public var playheadCentered = true
    public var zoomLevel: Double = 1
    /// −1 means automatic: the piano roll picks the pitch range from the notes.
    public var verticalZoom: Double = -1

    public init() {}

    // MARK: - Files

    /// The state at `url`. `unreadable` for a missing or damaged file, `newerVersion` for one this
    /// version must not touch.
    public static func read(from url: URL) throws -> ProjectState {
        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }

        let state: ProjectState

        do {
            state = try JSONDecoder().decode(ProjectState.self, from: data)
        } catch {
            throw ProjectError.unreadable(error.localizedDescription)
        }

        guard state.formatVersion <= currentFormatVersion else {
            throw ProjectError.newerVersion(state.formatVersion)
        }

        return state
    }

    /// Writes the state as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Selected groups

    /// The instrument groups named by a comma-separated list of ids, as the settings menu writes it.
    ///
    /// Ids that are not `InstrumentGroup` raw values are dropped rather than trusted, repeats collapse
    /// and the result comes back in enumerator order, so the same selection always reads the same way
    /// however it was typed.
    public static func parseSelectedGroups(_ csv: String) -> [Int32] {
        let ids = Set(
            csv.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })

        return InstrumentGroup.allCases.map(\.rawValue).filter(ids.contains)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case formatVersion, audioFileName, audioDisplayName, selectedGroups, mixer
        case exportTempo, gridOffsetSeconds, gridDivision, snapEnabled, targetProgram
        case workspace, playheadSeconds, playheadCentered, zoomLevel, verticalZoom
    }

    /// Every key falls back to its default, so a file written by a version that did not have one
    /// still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProjectState()

        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? defaults.formatVersion
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName) ?? defaults.audioFileName
        audioDisplayName = try container.decodeIfPresent(String.self, forKey: .audioDisplayName)
        selectedGroups =
            try container.decodeIfPresent([Int32].self, forKey: .selectedGroups) ?? defaults.selectedGroups
        mixer =
            try container.decodeIfPresent([Int: InstrumentChannelSettings].self, forKey: .mixer)
            ?? defaults.mixer
        exportTempo = try container.decodeIfPresent(Double.self, forKey: .exportTempo) ?? defaults.exportTempo
        gridOffsetSeconds =
            try container.decodeIfPresent(Double.self, forKey: .gridOffsetSeconds) ?? defaults.gridOffsetSeconds
        gridDivision = try container.decodeIfPresent(GridDivision.self, forKey: .gridDivision) ?? defaults.gridDivision
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? defaults.snapEnabled
        targetProgram = try container.decodeIfPresent(Int.self, forKey: .targetProgram)
        workspace = try container.decodeIfPresent(Workspace.self, forKey: .workspace) ?? defaults.workspace
        playheadSeconds =
            try container.decodeIfPresent(Double.self, forKey: .playheadSeconds) ?? defaults.playheadSeconds
        playheadCentered =
            try container.decodeIfPresent(Bool.self, forKey: .playheadCentered) ?? defaults.playheadCentered
        zoomLevel = try container.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? defaults.zoomLevel
        verticalZoom =
            try container.decodeIfPresent(Double.self, forKey: .verticalZoom) ?? defaults.verticalZoom
    }
}
