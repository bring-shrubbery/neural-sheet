import Foundation

/// What makes a project edited: the fields whose change the user would expect to be asked about
/// before closing. The app builds one from the model after every save and compares it to the one
/// it builds now; the view state (tab, playhead, zoom, note selection) is not in it, so moving the
/// playhead never puts the dot in the close button, and undoing back to the saved notes clears it.
///
/// The audio is compared by the app on the source object itself, since the audio type is the app's.
public struct ProjectContent: Equatable, Sendable {
    public var transcription: ProjectTranscription?
    public var selectedGroups: [Int32]
    public var mixer: [Int: InstrumentChannelSettings]
    public var exportTempo: Double
    public var gridOffsetSeconds: Double
    public var gridDivision: GridDivision
    /// The tempo map: a tempo change or a meter is an edit like the BPM.
    public var gridSegments: [GridSegment]
    /// The grid's swing: changing it is an edit like the division.
    public var gridSwing: Double
    public var snapEnabled: Bool
    public var targetProgram: Int?
    public var key: MusicalKey?
    public var arrangement: ScoreArrangement
    /// The chord symbols: a correction is a project-state edit like the key (chord symbols
    /// design §2), not a note edit.
    public var chords: [ChordEvent]

    public init(
        transcription: ProjectTranscription?,
        selectedGroups: [Int32],
        mixer: [Int: InstrumentChannelSettings],
        exportTempo: Double,
        gridOffsetSeconds: Double,
        gridDivision: GridDivision,
        gridSegments: [GridSegment] = [],
        gridSwing: Double = TempoGrid.straightSwing,
        snapEnabled: Bool,
        targetProgram: Int?,
        key: MusicalKey? = nil,
        arrangement: ScoreArrangement = ScoreArrangement(),
        chords: [ChordEvent] = []
    ) {
        self.transcription = transcription
        self.selectedGroups = selectedGroups
        self.mixer = mixer
        self.exportTempo = exportTempo
        self.gridOffsetSeconds = gridOffsetSeconds
        self.gridDivision = gridDivision
        self.gridSegments = gridSegments
        self.gridSwing = gridSwing
        self.snapEnabled = snapEnabled
        self.targetProgram = targetProgram
        self.key = key
        self.arrangement = arrangement
        self.chords = chords
    }
}
