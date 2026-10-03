import Foundation

/// What the app remembers between launches, for every window: the model it transcribes with, how
/// large the editor is drawn, whether tooltips appear and what the MIDI writer does when a
/// transcription has more instruments than the file has channels.
///
/// Stored as an XML property list at whatever URL the caller passes — the app's is
/// `~/Library/NeuralSheet/global.settings`, but nothing here knows that, which is what lets the tests
/// stay in a temp directory. Saving always writes every key, so the file is a full record of what the
/// app is using rather than a diff against defaults; loading tolerates a missing or damaged file and a
/// file written by an older version that lacks a key, because losing a preference must never stop the
/// app from opening. Also holds the recent projects the user removed from the welcome window's list.
public struct GlobalSettings: Codable, Equatable, Sendable {
    public var modelSize: ModelSize = .medium
    public var editorScale: Double = 1.0
    public var tooltipsVisible = true
    public var midiOverflowMode: MidiOverflowMode = .reuseChannels
    /// The Transcribe toolbar's Stems toggle (stem separation design §2): separate the take
    /// first and transcribe each stem with its own instruments.
    public var separateStems = false

    /// View → Show Confidence (confidence design §2): the roll shades notes by how sure the
    /// model was rather than by velocity.
    public var showsConfidence = false

    /// Settings → Model → After transcription (confidence design §2): a run drops notes shorter
    /// than this, in seconds, before they land; 0 is off. Also what Select Doubtful Notes
    /// counts as too short.
    public var minimumNoteLength: Double = 0

    /// The same section's other control: a run drops notes the model was less sure of than this,
    /// 0…1; 0 is off.
    public var minimumConfidence: Double = 0

    /// Recent projects the user removed from the welcome window's list, by path: the system's
    /// recent-documents list has no per-item removal, so the app filters it through this. A
    /// project opened or saved again leaves the list.
    public var hiddenRecentProjects: [String] = []

    public init(
        modelSize: ModelSize = .medium,
        editorScale: Double = 1.0,
        tooltipsVisible: Bool = true,
        midiOverflowMode: MidiOverflowMode = .reuseChannels,
        separateStems: Bool = false,
        showsConfidence: Bool = false,
        minimumNoteLength: Double = 0,
        minimumConfidence: Double = 0,
        hiddenRecentProjects: [String] = []
    ) {
        self.modelSize = modelSize
        self.editorScale = editorScale
        self.tooltipsVisible = tooltipsVisible
        self.midiOverflowMode = midiOverflowMode
        self.separateStems = separateStems
        self.showsConfidence = showsConfidence
        self.minimumNoteLength = minimumNoteLength
        self.minimumConfidence = minimumConfidence
        self.hiddenRecentProjects = hiddenRecentProjects
    }

    // MARK: - Files

    /// The settings at `url`, or the defaults if there is no file, it cannot be read, or it is not a
    /// property list this version understands. Never throws: there is nothing a caller could do about
    /// a damaged preferences file that starting fresh does not do better.
    public static func load(from url: URL) -> GlobalSettings {
        guard let data = try? Data(contentsOf: url),
            let settings = try? PropertyListDecoder().decode(GlobalSettings.self, from: data)
        else {
            return GlobalSettings()
        }

        return settings
    }

    /// Writes every key as an XML property list, replacing whatever was there.
    public func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case modelSize, editorScale, tooltipsVisible, midiOverflowMode, separateStems
        case showsConfidence, minimumNoteLength, minimumConfidence, hiddenRecentProjects
    }

    /// Every key falls back to its default, so a file written by a version that did not have one
    /// still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GlobalSettings()

        modelSize = try container.decodeIfPresent(ModelSize.self, forKey: .modelSize) ?? defaults.modelSize
        editorScale = try container.decodeIfPresent(Double.self, forKey: .editorScale) ?? defaults.editorScale
        tooltipsVisible =
            try container.decodeIfPresent(Bool.self, forKey: .tooltipsVisible) ?? defaults.tooltipsVisible
        midiOverflowMode =
            try container.decodeIfPresent(MidiOverflowMode.self, forKey: .midiOverflowMode)
            ?? defaults.midiOverflowMode
        separateStems = try container.decodeIfPresent(Bool.self, forKey: .separateStems) ?? defaults.separateStems
        showsConfidence =
            try container.decodeIfPresent(Bool.self, forKey: .showsConfidence) ?? defaults.showsConfidence
        minimumNoteLength =
            try container.decodeIfPresent(Double.self, forKey: .minimumNoteLength) ?? defaults.minimumNoteLength
        minimumConfidence =
            try container.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? defaults.minimumConfidence
        hiddenRecentProjects =
            try container.decodeIfPresent([String].self, forKey: .hiddenRecentProjects)
            ?? defaults.hiddenRecentProjects
    }
}
