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

    /// View → Show Pitch Curves (pitch curves design §2): the roll draws each tracked note's
    /// curve through it. On by default: a curve only exists once Track Pitch has been asked for.
    public var showsPitchCurves = true

    /// Recent projects the user removed from the welcome window's list, by path: the system's
    /// recent-documents list has no per-item removal, so the app filters it through this. A
    /// project opened or saved again leaves the list.
    public var hiddenRecentProjects: [String] = []

    /// Settings → Audio → Sound bank (click design §2): the `.sf2` or `.dls` every synth plays
    /// through, by path, or nil for the system's General MIDI bank. A plain path is enough: the
    /// app is not sandboxed, so no security-scoped bookmark is needed to reach the file again.
    public var soundBankPath: String? = nil

    /// Settings → Audio → Count-in: bars of click before a take starts, 0 (off), 1 or 2.
    public var countInBars = 0

    /// Settings → Audio → Click while recording: the click carries on through the take, through
    /// the output only.
    public var clickWhileRecording = false

    /// Audio → Input (system audio design §2): the recording input as
    /// ``RecordingInputSetting/encoded`` has it, or empty for the system default.
    public var recordingInput = ""

    /// Audio → MIDI Output (MIDI out design §2): the chosen CoreMIDI destination's
    /// `kMIDIPropertyUniqueID`, or nil for None. A destination missing at launch reads as None
    /// without changing this, so it comes back when the device does.
    public var midiOutUniqueID: Int32? = nil

    /// Audio → MIDI Output → Mute Built-in Synth While Sending: while a destination is chosen the
    /// app's own synths are silent, so the DAW's instruments are what is heard.
    public var midiOutMutesSynth = true

    /// File → Export Audio…'s accessory (audio export design §2): the *What*, the *Format* and
    /// whether *Marked range* was chosen, offered again next time.
    public var audioExportWhat: AudioExportWhat = .midi
    public var audioExportFormat: AudioExportFormat = .wav24
    public var audioExportMarkedRange = false

    /// What the Count-in picker offers.
    public static let countInChoices = [0, 1, 2]

    public init(
        modelSize: ModelSize = .medium,
        editorScale: Double = 1.0,
        tooltipsVisible: Bool = true,
        midiOverflowMode: MidiOverflowMode = .reuseChannels,
        separateStems: Bool = false,
        showsConfidence: Bool = false,
        minimumNoteLength: Double = 0,
        minimumConfidence: Double = 0,
        showsPitchCurves: Bool = true,
        hiddenRecentProjects: [String] = [],
        soundBankPath: String? = nil,
        countInBars: Int = 0,
        clickWhileRecording: Bool = false,
        recordingInput: String = "",
        midiOutUniqueID: Int32? = nil,
        midiOutMutesSynth: Bool = true,
        audioExportWhat: AudioExportWhat = .midi,
        audioExportFormat: AudioExportFormat = .wav24,
        audioExportMarkedRange: Bool = false
    ) {
        self.modelSize = modelSize
        self.editorScale = editorScale
        self.tooltipsVisible = tooltipsVisible
        self.midiOverflowMode = midiOverflowMode
        self.separateStems = separateStems
        self.showsConfidence = showsConfidence
        self.minimumNoteLength = minimumNoteLength
        self.minimumConfidence = minimumConfidence
        self.showsPitchCurves = showsPitchCurves
        self.hiddenRecentProjects = hiddenRecentProjects
        self.soundBankPath = soundBankPath
        self.countInBars = countInBars
        self.clickWhileRecording = clickWhileRecording
        self.recordingInput = recordingInput
        self.midiOutUniqueID = midiOutUniqueID
        self.midiOutMutesSynth = midiOutMutesSynth
        self.audioExportWhat = audioExportWhat
        self.audioExportFormat = audioExportFormat
        self.audioExportMarkedRange = audioExportMarkedRange
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
        case showsConfidence, minimumNoteLength, minimumConfidence, showsPitchCurves, hiddenRecentProjects
        case soundBankPath, countInBars, clickWhileRecording, recordingInput
        case midiOutUniqueID, midiOutMutesSynth
        case audioExportWhat, audioExportFormat, audioExportMarkedRange
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
        showsPitchCurves =
            try container.decodeIfPresent(Bool.self, forKey: .showsPitchCurves) ?? defaults.showsPitchCurves
        hiddenRecentProjects =
            try container.decodeIfPresent([String].self, forKey: .hiddenRecentProjects)
            ?? defaults.hiddenRecentProjects
        soundBankPath = try container.decodeIfPresent(String.self, forKey: .soundBankPath)
        let bars = try container.decodeIfPresent(Int.self, forKey: .countInBars) ?? defaults.countInBars
        countInBars = GlobalSettings.countInChoices.contains(bars) ? bars : defaults.countInBars
        clickWhileRecording =
            try container.decodeIfPresent(Bool.self, forKey: .clickWhileRecording) ?? defaults.clickWhileRecording
        recordingInput =
            try container.decodeIfPresent(String.self, forKey: .recordingInput) ?? defaults.recordingInput
        midiOutUniqueID = try container.decodeIfPresent(Int32.self, forKey: .midiOutUniqueID)
        midiOutMutesSynth =
            try container.decodeIfPresent(Bool.self, forKey: .midiOutMutesSynth) ?? defaults.midiOutMutesSynth
        // A value a later version wrote and this one does not know falls back rather than
        // failing the whole file.
        audioExportWhat = (try? container.decodeIfPresent(AudioExportWhat.self, forKey: .audioExportWhat))
            .flatMap { $0 } ?? defaults.audioExportWhat
        audioExportFormat = (try? container.decodeIfPresent(AudioExportFormat.self, forKey: .audioExportFormat))
            .flatMap { $0 } ?? defaults.audioExportFormat
        audioExportMarkedRange =
            try container.decodeIfPresent(Bool.self, forKey: .audioExportMarkedRange) ?? defaults.audioExportMarkedRange
    }
}
