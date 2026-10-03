import Foundation
import NeuralSheetCore
import Observation

/// The iOS app's model (iOS app design §2): one per open document, built from the same pieces as
/// the Mac's `AppModel` -- the playback engine, the take, the note document, the editor state and
/// the project fields `project.json` keeps. It installs that state from a package and snapshots it
/// back; the take comes in through `+Imports` and `+Recording`, the notes through
/// `+Transcription` (sub-issue D); the editing commands come with sub-issue F.
///
/// The field list and the two directions follow `AppModel+Project.swift` and
/// `AppModel+ProjectOpen.swift`, so a package the Mac saved reads back field for field and one
/// saved here opens on the Mac unchanged.
@Observable
final class MobileModel {
    @ObservationIgnored let engine: PlaybackEngine

    /// Why the project's take or notes could not be loaded, for the screen to say; nil when all
    /// is well.
    var loadProblem: String?

    // MARK: - The take

    /// The take, or nil for a project without audio.
    private(set) var source: SourceAudio? {
        didSet { if oldValue !== source { sourceGeneration &+= 1 } }
    }

    /// Bumped whenever ``source`` becomes a different take, so a save can tell the take it opened
    /// with (whose bytes the package already has) from a new one, as the Mac's dirty rule does.
    private(set) var sourceGeneration = 0

    /// Seconds of audio: 0 without a take.
    var duration: Double { source?.duration ?? 0 }

    /// The file's name without its extension for an imported take, nil for a recording.
    var droppedFileName: String? { source?.droppedFileName }

    // MARK: - The transcription

    /// The editable notes: nil until a transcription exists.
    private(set) var document: NoteDocument?
    /// The model's own output, kept beside the document for Revert to Transcription.
    private(set) var rawNotes: [NoteEvent] = []
    /// The saved versions of the notes, oldest first (versions design §2).
    var versions: [NoteVersion] = []

    // MARK: - Project state

    /// The tool, selection, target instrument, snap, grid, key, chords and markers.
    var editor = EditorState()
    /// The instrument groups the next run transcribes; empty is automatic.
    var selectedGroups: [InstrumentGroup] = []
    /// The mix, keyed by program.
    var mixer = InstrumentMixerState()
    /// How the Score tab shows the transcription (arrangement design §3.1).
    var arrangement = ScoreArrangement()
    var clickEnabled = false
    var clickGainDb = ProjectState.defaultClickGainDb

    // MARK: - View state (saved, never an edit)

    var workspace: Workspace = .transcribe
    var playheadSeconds: Double = 0
    var followPlayhead = true
    var zoomLevel: Double = 1
    var verticalZoom: Double = -1
    /// The instrument singled out from the iPad's sidebar: the roll fades every other one, as a
    /// strip click does on the Mac. Not saved.
    var highlightedProgram: Int?
    /// True from Play until Pause or the take running out: what wakes the timeline's display link,
    /// the engine's own flag not being observable. Not saved.
    var isTransportRunning = false

    /// The project tempo: the grid's BPM and the tempo the MIDI file is written at.
    var exportTempo: Double { editor.grid.bpm }

    // MARK: - Runs, takes and imports (sub-issue D)

    /// The run in flight, or nil; `+Transcription` is its only writer.
    var run: RunState?
    /// What the run in flight has found so far, merged: what the screen counts while it streams.
    var streamedNotes: [NoteEvent] = []
    /// How long the last finished run took, in seconds, for the screen's result line.
    var lastRunSeconds: Double?
    /// A take being counted in or recorded, or nil; `+Recording`'s.
    var recording: RecordingState?
    /// True while an imported file is being copied, extracted or decoded.
    var isImporting = false
    /// The message box the screen shows, or nil.
    var alert: MobileAlert?

    @ObservationIgnored let transcriber = TranscriptionEngine()
    @ObservationIgnored let separator = StemSeparator()
    @ObservationIgnored let staging = TranscriptionStaging()
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var runSupport: RunSupport?
    /// The run in flight's cancel and thermal gate, reachable from any thread.
    @ObservationIgnored var runControl: RunControl?
    /// The transcription a run replaces: saved as a version when the run lands, put back when it
    /// is cancelled or fails.
    @ObservationIgnored var transcriptionBeforeRun: ProjectSnapshot?
    /// Set when the system ended a run's background time: the run starts again on return.
    @ObservationIgnored var resumeRunWhenActive = false
    @ObservationIgnored lazy var recorder = Recorder(engine: engine, paths: .standard)
    @ObservationIgnored var recordingPoll: Task<Void, Never>?
    @ObservationIgnored var countInBeats: [Double] = []

    /// The document's undo manager, which iOS autosaves by: a new take and a landed run register
    /// with it, so the document is saved (sub-issue F registers the edits).
    @ObservationIgnored weak var undoManager: UndoManager?

    init(engine: PlaybackEngine = PlaybackEngine()) {
        self.engine = engine
    }

    // MARK: - Install

    /// Decodes the take a package names, at the engine's rate. Named after its file unless the
    /// project says it was a recording (no display name), as on the Mac.
    func loadAudio(url: URL, package: ProjectPackage) throws -> SourceAudio {
        try AudioFileLoader.load(url: url,
                                 deviceRate: engine.sampleRate,
                                 namedAfterFile: package.state.audioDisplayName != nil)
    }

    /// The package's state into the model, the Mac's `installProject` without the window: the
    /// settings, the take, then the notes -- only against the very audio they were made from.
    /// True when the notes were dropped (unreadable, or made from audio of another length), so
    /// the caller can say so before a save writes them away.
    @discardableResult
    func install(_ package: ProjectPackage, audio: SourceAudio?, transcriptionUnreadable: Bool) -> Bool {
        let saved = package.state

        selectedGroups = MobileModel.normalised(saved.selectedGroups.compactMap(InstrumentGroup.init(rawValue:)))
        mixer = InstrumentMixerState()
        mixer.settings = saved.mixer
        clickEnabled = saved.clickEnabled
        clickGainDb = min(max(saved.clickGainDb, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)

        var editor = EditorState()
        editor.grid = saved.tempoGrid
        editor.snapEnabled = saved.snapEnabled
        editor.key = saved.key
        editor.chords = saved.chords.sortedChords()
        editor.chordsEdited = saved.chordsEdited
        editor.markers = saved.markers.sortedMarkers()
        self.editor = editor

        arrangement = saved.arrangement
        workspace = saved.workspace
        playheadSeconds = saved.playheadSeconds
        followPlayhead = saved.playheadCentered
        zoomLevel = saved.zoomLevel
        verticalZoom = saved.verticalZoom

        source = audio
        document = nil
        rawNotes = []
        versions = []

        if let audio {
            engine.setSource(audio)
        }

        guard !transcriptionUnreadable else { return true }
        guard let transcription = package.transcription else { return false }
        guard let audio, audio.mono16k.count == transcription.sourceSampleCount else { return true }

        rawNotes = transcription.rawNotes
        document = transcription.document
        versions = transcription.versions

        if let target = saved.targetProgram {
            self.editor.targetProgram = target
        }

        publishNotes()

        return false
    }

    // MARK: - A new take and new notes

    /// A take becomes the project's, with no transcription: the Mac's `installSource` after a
    /// clear. The selection and the settings stay, as they do on the Mac.
    func installSource(_ audio: SourceAudio) {
        source = audio
        engine.setSource(audio)
        document = nil
        rawNotes = []
        streamedNotes = []
        lastRunSeconds = nil
        playheadSeconds = 0
        editor.selection = []
        publishNotes()
    }

    /// Makes the document from the model's own output, as the Mac's `installDocument` does: the
    /// merge is the post-processing every raw note goes through, and the ids start again.
    func installDocument(rawNotes: [NoteEvent]) {
        self.rawNotes = rawNotes
        document = NoteDocument(events: mergeOverlappingNotesWithSamePitch(rawNotes))
        streamedNotes = []
        editor.selection = []
        publishNotes()
    }

    /// While a run streams: its raw notes so far, and what is drawn and played of them. There is
    /// no document until the run lands.
    func streamRawNotes(_ rawNotes: [NoteEvent]) {
        self.rawNotes = rawNotes
        document = nil
        streamedNotes = TranscriptionRun.streamedNotes(rawNotes)
        publishNotes()
    }

    // MARK: - Snapshots for undo and for a run

    /// The take and the transcription, as a run or an import replaces them.
    struct ProjectSnapshot {
        var source: SourceAudio?
        var rawNotes: [NoteEvent]
        var document: NoteDocument?
        var versions: [NoteVersion]
    }

    func projectSnapshot() -> ProjectSnapshot {
        ProjectSnapshot(source: source, rawNotes: rawNotes, document: document, versions: versions)
    }

    func restore(_ snapshot: ProjectSnapshot) {
        if snapshot.source !== source {
            source = snapshot.source
            engine.setSource(snapshot.source)
        }

        rawNotes = snapshot.rawNotes
        document = snapshot.document
        versions = snapshot.versions
        streamedNotes = []
        editor.selection = []
        publishNotes()
    }

    /// Registers the change from `before` to now with the document's undo manager, which is what
    /// marks an iOS document edited and gets it autosaved. Undo puts `before` back; redo the
    /// state it replaced.
    func registerUndo(_ actionName: String, before: ProjectSnapshot) {
        guard let undoManager else { return }

        undoManager.registerUndo(withTarget: self) { model in
            let after = model.projectSnapshot()
            model.restore(before)
            model.registerUndo(actionName, before: after)
        }
        undoManager.setActionName(actionName)
    }

    /// The document's notes to the synths and the scheduler, as the Mac's `publishNotes` does;
    /// while a run streams, what it has found so far.
    func publishNotes() {
        let notes = document?.events ?? streamedNotes

        for program in Set(notes.map(\.program)).sorted() {
            engine.synthBank.ensureInstrument(program: program)
        }

        engine.synthBank.scheduler.swap(notes: notes)
        engine.refreshGains()
    }

    // MARK: - Snapshots

    /// The transcription as it stands, or nil without one.
    func transcriptionSnapshot() -> ProjectTranscription? {
        guard let document, let source else { return nil }

        return ProjectTranscription(sourceSampleCount: source.mono16k.count,
                                    rawNotes: rawNotes,
                                    document: document,
                                    versions: versions)
    }

    /// Everything `project.json` holds, field for field as the Mac's `projectState(audioFileName:)`.
    func projectState(audioFileName: String) -> ProjectState {
        var state = ProjectState()
        state.audioFileName = audioFileName
        state.audioDisplayName = droppedFileName
        state.selectedGroups = selectedGroups.map(\.rawValue)
        state.mixer = mixer.settings
        state.exportTempo = exportTempo
        state.gridOffsetSeconds = editor.grid.offsetSeconds
        state.gridDivision = editor.grid.division
        state.gridSegments = editor.grid.segments
        state.gridSwing = editor.grid.swing
        state.snapEnabled = editor.snapEnabled
        state.targetProgram = editor.targetProgram
        state.key = editor.key
        state.chords = editor.chords
        state.chordsEdited = editor.chordsEdited
        state.markers = editor.markers
        state.clickEnabled = clickEnabled
        state.clickGainDb = clickGainDb
        state.arrangement = arrangement
        state.workspace = workspace.savedWorkspace
        state.playheadSeconds = playheadSeconds
        state.playheadCentered = followPlayhead
        state.zoomLevel = zoomLevel
        state.verticalZoom = verticalZoom

        return state
    }

    /// The package a save writes: the state and the transcription.
    func projectPackage(audioFileName: String) -> ProjectPackage {
        ProjectPackage(state: projectState(audioFileName: audioFileName), transcription: transcriptionSnapshot())
    }

    // MARK: - Instrument selection

    /// Adds or removes one group, as the Mac's `setSelected`. Not while a run is in flight: the
    /// run has its own copy, and a change would only mislead.
    func setSelected(_ group: InstrumentGroup, _ on: Bool) {
        guard run == nil else { return }

        var groups = selectedGroups

        if on {
            groups.append(group)
        } else {
            groups.removeAll { $0 == group }
        }

        let normalised = MobileModel.normalised(groups)

        if normalised != selectedGroups {
            selectedGroups = normalised
        }
    }

    /// Back to Automatic.
    func clearSelection() {
        guard run == nil, !selectedGroups.isEmpty else { return }

        selectedGroups = []
    }

    /// Enumerator order, duplicates dropped, as the Mac keeps ``selectedGroups``.
    static func normalised(_ groups: [InstrumentGroup]) -> [InstrumentGroup] {
        let chosen = Set(groups)

        return InstrumentGroup.allCases.filter(chosen.contains)
    }
}
