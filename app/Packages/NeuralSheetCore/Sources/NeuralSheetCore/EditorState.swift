import Foundation

/// The editor's own state, shared on the model because the AppKit roll and the SwiftUI inspector
/// both read it (design §5.3). In the core package so the iOS model holds the same one (iOS app
/// design §2).
public struct EditorState: Equatable, Sendable {
    public enum Tool: Equatable, Sendable {
        case select, draw, erase
    }

    public var tool: Tool = .select
    public var selection: Set<NoteID> = []
    /// The instrument new notes go to: the first strip's until one is chosen in the sidebar or
    /// assigned to a selection, then that one. Re-validated against the mixer's entries.
    public var targetProgram: Int = 0
    public var snapEnabled = true
    public var grid = TempoGrid()
    /// The project's key (key design §4): the roll's scale highlight, the score's signature
    /// and Snap to Scale's target. Nil for none. Saved with the project.
    public var key: MusicalKey?
    /// The chord symbols in time order (chord symbols design §2): the Edit tab's lane, the score's
    /// line and the MusicXML's harmony. Saved with the project; `AppModel+Chords.swift` writes it.
    public var chords: [ChordEvent] = []
    /// Whether the user changed the list since Detect filled it, so Detect asks before replacing.
    public var chordsEdited = false
    /// The section markers in time order (markers and lyrics design §2): the ruler's flags, the
    /// score's rehearsal marks and both exports. Saved with the project; `AppModel+Markers.swift`
    /// writes it.
    public var markers: [Marker] = []
    /// The marker just added from the menu, for the timeline to open its card on so it can be
    /// named at once. Transient; the timeline hands it back once shown.
    public var markerToRename: UUID?
    /// The note the lyric card is open on (markers and lyrics design §2), nil with none.
    /// Transient: `AppModel+Lyrics.swift` moves it along as syllables are entered.
    public var lyricNote: NoteID?
    /// The stretch marked on the ruler for Re-transcribe (region design §4.2), half-open seconds.
    /// Transient: not in the project file.
    public var range: Range<Double>?
    /// The instruments the last Re-transcribe popup settled on this session; nil until it has
    /// been opened, when the popup presets the instruments in the mix. Empty is Automatic.
    public var retranscribeGroups: [InstrumentGroup]?

    public init() {}

    /// A drawn or inserted note is one division long.
    public var drawLength: Double { grid.step }
}
