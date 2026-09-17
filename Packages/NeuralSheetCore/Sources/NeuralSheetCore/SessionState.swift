import Foundation

/// One document's worth of state: what audio it was working on, where the playhead and the zoom
/// were, which instrument groups the user picked and how the mix was set.
///
/// `sourceAudioPath` is a path rather than the audio itself — reopening a session re-reads the file
/// from disk — and the transcription is deliberately not part of this: a reloaded session gives the
/// audio back, not the notes.
///
/// Stored as JSON at whatever URL the caller passes, with sorted keys and indentation so two saves of
/// the same state give the same bytes and a session file stays readable (and diffable) by hand.
/// Loading a missing or damaged file gives the defaults rather than throwing, and a key that is not
/// there falls back to its own default, so a file from an older version still opens.
public struct SessionState: Codable, Equatable, Sendable {
    public var exportTempo: Double = 120
    public var midiOverflowMode: MidiOverflowMode = .reuseChannels
    public var sourceAudioPath: String = ""
    public var playheadSeconds: Double = 0
    public var playheadCentered = true
    public var zoomLevel: Double = 1
    /// −1 means automatic: the piano roll picks the pitch range from the notes.
    public var verticalZoom: Double = -1
    /// `InstrumentGroup` raw values, in enumerator order. Empty means automatic.
    public var selectedGroups: [Int32] = []
    /// The mix, keyed by program; an absent program is `InstrumentChannelSettings()`.
    public var mixer: [Int: InstrumentChannelSettings] = [:]

    public init() {}

    // MARK: - Files

    /// The session at `url`, or a fresh one if there is no file, it cannot be read, or it is not JSON
    /// this version understands.
    public static func load(from url: URL) -> SessionState {
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else {
            return SessionState()
        }

        return state
    }

    /// Writes the session as JSON, replacing whatever was there.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Selected groups

    /// The instrument groups named by a comma-separated list of ids, as the settings menu and older
    /// sessions write it.
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
        case exportTempo, midiOverflowMode, sourceAudioPath, playheadSeconds, playheadCentered
        case zoomLevel, verticalZoom, selectedGroups, mixer
    }

    /// Every key falls back to its default, so a file written by a version that did not have one
    /// still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SessionState()

        exportTempo = try container.decodeIfPresent(Double.self, forKey: .exportTempo) ?? defaults.exportTempo
        midiOverflowMode =
            try container.decodeIfPresent(MidiOverflowMode.self, forKey: .midiOverflowMode)
            ?? defaults.midiOverflowMode
        sourceAudioPath =
            try container.decodeIfPresent(String.self, forKey: .sourceAudioPath) ?? defaults.sourceAudioPath
        playheadSeconds =
            try container.decodeIfPresent(Double.self, forKey: .playheadSeconds) ?? defaults.playheadSeconds
        playheadCentered =
            try container.decodeIfPresent(Bool.self, forKey: .playheadCentered) ?? defaults.playheadCentered
        zoomLevel = try container.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? defaults.zoomLevel
        verticalZoom =
            try container.decodeIfPresent(Double.self, forKey: .verticalZoom) ?? defaults.verticalZoom
        selectedGroups =
            try container.decodeIfPresent([Int32].self, forKey: .selectedGroups) ?? defaults.selectedGroups
        mixer =
            try container.decodeIfPresent([Int: InstrumentChannelSettings].self, forKey: .mixer)
            ?? defaults.mixer
    }
}
