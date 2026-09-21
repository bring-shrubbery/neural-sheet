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
    public var snapEnabled: Bool
    public var targetProgram: Int?

    public init(
        transcription: ProjectTranscription?,
        selectedGroups: [Int32],
        mixer: [Int: InstrumentChannelSettings],
        exportTempo: Double,
        gridOffsetSeconds: Double,
        gridDivision: GridDivision,
        snapEnabled: Bool,
        targetProgram: Int?
    ) {
        self.transcription = transcription
        self.selectedGroups = selectedGroups
        self.mixer = mixer
        self.exportTempo = exportTempo
        self.gridOffsetSeconds = gridOffsetSeconds
        self.gridDivision = gridDivision
        self.snapEnabled = snapEnabled
        self.targetProgram = targetProgram
    }
}
