import AVFoundation
import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The one main-actor object every view reads and every command goes through: the §11.1 state
/// machine, what audio is loaded, the transcription as it streams in, the mix, the transport, the
/// model panel and the updater.
///
/// Everything here is the main actor's. The engine, the recorder and the downloader call back on
/// their own threads and are hopped onto the main actor before they touch anything of this
/// object's; the transcription's per-chunk notes go through ``TranscriptionStaging`` and a 30 Hz
/// drain (`AppModel+Transcription.swift`), the way the C++ `TranscriptionManager` did it.
///
/// The settings are written by `Persistence`; the project by `AppModel+Project.swift`.
@MainActor @Observable final class AppModel {
    // MARK: - Dependencies

    let paths: AppPaths
    let engine: PlaybackEngine
    let recorder: Recorder
    let transcriber: TranscriptionEngine
    /// The stem separation (stem separation design §3), for a run with Stems on.
    let separator = StemSeparator()
    let modelStore: ModelStore
    let downloader: ModelDownloader

    // MARK: - Dialogs

    /// Installed by the view layer: `(title, body)` for every §11.7 message box. Nil drops the
    /// message, which is what happens before a window exists.
    @ObservationIgnored var presentError: ((String, String) -> Void)?

    /// Installed by the view layer: `(title, body, confirm button title, completion)`. Nil
    /// confirms at once, which is what happens before a window exists.
    @ObservationIgnored var presentConfirm: ((String, String, String, @escaping (Bool) -> Void) -> Void)?

    /// Installed by the view layer: `(title, label, range, initial, suffix, completion)` for
    /// the number alerts By Interval… and Scale… (editor commands design §2); the completion runs
    /// only on OK. Nil drops the request, which is what happens before a window exists.
    @ObservationIgnored var presentNumber: ((String, String, ClosedRange<Int>, Int, String, @escaping (Int) -> Void) -> Void)?

    /// Installed by the view layer: `(title, label, initial text, completion)` for the text
    /// alert Save Version… asks its name with (versions design §2); the completion runs only on
    /// OK. Nil drops the request, which is what happens before a window exists.
    @ObservationIgnored var presentText: ((String, String, String, @escaping (String) -> Void) -> Void)?

    /// The last numbers By Interval… and Scale… were given, offered again next time; for the
    /// session, so a new project keeps them (editor commands design §2).
    @ObservationIgnored var lastTransposeSemitones = 7
    @ObservationIgnored var lastVelocityPercent = 100

    /// What the save-changes sheet came back with.
    enum SaveReviewChoice {
        case save, discard, cancel
    }

    /// Installed by the view layer: `(project title, completion)` for the standard "Do you want
    /// to save the changes…" sheet. Nil with nothing to lose proceeds without saving, which is
    /// what happens before a window exists; nil with unsaved changes is a wiring bug, said so in
    /// debug (`reviewProject`).
    @ObservationIgnored var presentSaveReview: ((String, @escaping (SaveReviewChoice) -> Void) -> Void)?

    /// Installed by the view layer: `(project title, completion)` for "Do you want to revert…".
    /// Nil declines.
    @ObservationIgnored var presentRevert: ((String, @escaping (Bool) -> Void) -> Void)?

    /// What the Import MIDI question came back with (MIDI import design §2).
    enum MIDIImportChoice {
        case replace, add, cancel
    }

    /// Installed by the view layer: `(file name, completion)` for "Replace the notes" / "Add to
    /// the notes" / Cancel. Nil cancels, which is what happens before a window exists.
    @ObservationIgnored var presentMIDIImportChoice: ((String, @escaping (MIDIImportChoice) -> Void) -> Void)?

    /// Cancels the roll drag in progress and says whether there was one; installed by the edit
    /// controller, a no-op without a drag.
    @ObservationIgnored var dragCanceller: (() -> Bool)?

    /// Every dialog goes through here: a message with nobody to show it is a wiring bug, which
    /// a debug build says so about rather than swallowing.
    func showError(_ title: String, _ body: String) {
        guard let presentError else {
            assertionFailure("presentError is not installed; dropped: \(title) / \(body)")
            return
        }

        presentError(title, body)
    }

    // MARK: - State

    private(set) var state: AppState = .empty

    /// The tab on show (design §3.2). Only `setWorkspace` and `transition` write it.
    private(set) var workspace: Workspace = .transcribe

    /// The take, or nil while empty or recording.
    // Internal setter: written from AppModel+Loading.swift.
    var source: SourceAudio? {
        didSet { if oldValue !== source { sourceGeneration &+= 1 } }
    }

    /// Bumped whenever ``source`` becomes a different take (or none), so the dirty rule can tell a
    /// replaced or removed take from the saved one without holding it. A write that changes
    /// nothing -- `clearNow()` on a project that is already empty, as a too-short or failed take
    /// leaves it -- does not count, or Record then Stop would make a fresh project edited.
    private(set) var sourceGeneration = 0

    /// Seconds of audio: 0 when there is none, growing live while recording (refreshed by the
    /// display-link tick), `source.duration` otherwise.
    // Internal setter: written from AppModel+Recording.swift, +Loading.swift and +Playback.swift.
    var duration: Double = 0 {
        didSet {
            if duration != oldValue {
                applyLoop()
                refreshClickTrack()
            }
        }
    }

    /// The dropped file's name without its extension, which the toolbar shows and the MIDI exit is
    /// named after. Nil for a recorded take.
    var droppedFileName: String? { source?.droppedFileName }

    /// What the waveform draws: the recorder's live peaks while a take is in progress, the take's
    /// own once it has been read back, and an empty set otherwise.
    var peaks: WaveformPeaks {
        if state == .recording {
            return recorder.livePeaks
        }

        return source?.peaks ?? emptyPeaks
    }

    /// A reference so the empty case is stable across reads.
    @ObservationIgnored private let emptyPeaks = WaveformPeaks()

    // MARK: - Transcription

    /// Everything the transcription pipeline writes, as one value: `AppModel+Transcription.swift`
    /// is the only writer, and the read-only members below are what everyone else sees.
    struct TranscriptionState: Equatable {
        /// The model's own output accumulated across chunks; `notes` is derived from it.
        var rawNotes: [NoteEvent] = []
        /// The post-processed notes: what the piano roll draws, the synth plays, the export writes.
        var notes: [NoteEvent] = []
        /// Seconds: every note ending before this has been reported (the decode frontier).
        var finalizedThrough: Double = 0
        /// 0…1 while processing, 1 once populated.
        var progress: Float = 0
        /// True from the cancel click until the engine acknowledges it at the next chunk boundary.
        var cancelLatched = false
        /// True from `transcriber.run` until its completion has been handled on the main actor.
        var jobActive = false
        /// The checkpoint the run in flight loaded, for the unsupported-version message.
        var jobModelPath: URL?
        /// "Transcribe" or "Stems": what the run in flight is, for the automatic version its
        /// landing saves first (versions design §2).
        var jobRunName: String?
    }

    var transcription = TranscriptionState()

    /// The post-processed notes: what the piano roll draws, what the synth plays, what is exported.
    var notes: [NoteEvent] { transcription.notes }

    /// Seconds: every note ending before this has been reported (the decode frontier).
    var finalizedThrough: Double { transcription.finalizedThrough }

    /// 0…1 while processing, 1 once populated.
    var transcriptionProgress: Float { transcription.progress }

    /// True from the cancel click until the engine acknowledges it at the next chunk boundary. The
    /// progress group dims on it (§3.4).
    var cancelLatched: Bool { transcription.cancelLatched }

    /// True while a run owns the notes: from `transcriber.run` until its completion has landed.
    var jobActive: Bool { transcription.jobActive }

    /// Where the engine thread leaves each chunk for the 30 Hz drain.
    @ObservationIgnored let staging = TranscriptionStaging()

    @ObservationIgnored var drainTimer: Timer?

    /// The editable transcription: nil until a run completes or a project is opened. Once it
    /// exists, `transcription.notes` is always `document.events` (`AppModel+Editing.swift`).
    var document: NoteDocument?

    /// The saved versions of the notes, oldest first (versions design §2); the "Transcription"
    /// entry is not among them. `AppModel+Versions.swift` is the only writer besides the clear
    /// that drops the take. Saved with the project inside `transcription.json`.
    var versions: [NoteVersion] = []

    /// The version ghosted behind the roll, or nil (versions design §2). View state: not saved,
    /// dropped with the transcription.
    var comparedVersion: NoteVersion?

    /// What the status bar says while comparing, kept current by `refreshComparison()` rather
    /// than matched on every read of the status line.
    var comparisonSummary: VersionComparisonSummary?

    /// Edit → Versions → Manage Versions…'s sheet.
    var isManageVersionsPresented = false

    /// The notes the toolbar's clear threw away, until the run that replaces them lands and
    /// saves them as "Before Transcribe" (versions design §2): today a re-run needs a clear
    /// first, so at the landing there is no document left to snapshot.
    @ObservationIgnored var notesBeforeRun: [NoteEvent]?

    /// The editor's tool, selection, target instrument, snap and grid.
    var editor = EditorState() {
        didSet {
            if editor.range != oldValue.range { applyLoop() }
            // The click's beats are the grid's (click design §2).
            if editor.grid != oldValue.grid { refreshClickTrack() }
        }
    }

    /// How the Score tab shows the transcription (arrangement design §3.1). Saved with the
    /// project; `AppModel+Arrangement.swift` is its only writer.
    var arrangement = ScoreArrangement()

    /// The tab note the Score tab has selected, whose string ↑/↓ move. Transient.
    var selectedTabNote: (program: Int, id: NoteID)?

    /// The region re-run in flight, or nil (`AppModel+RegionTranscription.swift`, its only
    /// writer). While it is set the editor is read-only and the clears refuse.
    var regionJob: RegionJob?

    /// The stems run in flight, or nil (`AppModel+Stems.swift`, its only writer). Only ever set
    /// while `jobActive`.
    var stemsJob: StemsJob?

    /// A video's audio being extracted and decoded, or nil (`AppModel+Import.swift`, its only
    /// writer besides ``clearNow()``, which cancels it). While it is set the state is `.empty`
    /// but nothing may start: a load, a record, a run or an open refuse as they do during a
    /// region job (input formats design §2).
    var importJob: Task<Void, Never>?

    /// Track Pitch in flight, or nil (`AppModel+PitchTracking.swift`, its only writer besides
    /// the clears, which cancel it). Edits may go on meanwhile; a region run may not start.
    var pitchJob: Task<Void, Never>?

    /// The file a video's audio was extracted to, while it is the take. It is not a recording by
    /// name, so the clear finds it here rather than by the recorder's prefix.
    @ObservationIgnored var importedAudioURL: URL?

    /// The take's kept separation, 24-bit `.caf` per stem in a folder of its own inside the
    /// recordings, or nil (audio export design §2). Set when a Stems run or Export Stems…
    /// separates the take; it goes with the take, the import folder's way: removed by every clear
    /// and close, and swept at launch with the rest of the recordings.
    var stemsFolder: URL?

    /// Export Audio…'s render in flight, or nil (`AppModel+AudioExport.swift`, its only writer).
    /// The progress sheet is up while it is set.
    var audioRender: AudioRenderJob?

    /// Export Stems…'s own separation, when the take has none kept, or nil
    /// (`AppModel+StemsExport.swift`, its only writer besides ``clearNow()``, which cancels it).
    var stemsExport: StemsExportJob?

    /// The instrument a strip click singled out: the roll fades every other instrument while it
    /// is set. Both tabs; not part of the project file.
    // Internal setter: AppModel+Loading.swift's resetTranscription clears it.
    var highlightedProgram: Int?

    /// A strip click: singles the instrument out in the roll, or clears the highlight when it is
    /// the one already singled out. In the Edit tab the same click also makes it the target,
    /// which never clears. Beside ``highlightedProgram`` because its setter is this file's.
    func toggleHighlight(program: Int) {
        guard mixer.entries.contains(where: { $0.program == program }) else { return }

        highlightedProgram = highlightedProgram == program ? nil : program

        if workspace == .edit {
            setTargetProgram(program)
        }
    }

    /// For an instrument that has left the mix.
    func clearHighlight() {
        highlightedProgram = nil
    }

    /// The one place the state changes. The pipeline's and the commands'; views never call it.
    func transition(to newState: AppState) {
        guard newState != state else { return }

        state = newState

        // The Edit tab is only for a finished transcription.
        if newState != .populated, workspace != .transcribe {
            workspace = .transcribe
        }

        // The range marks a stretch of the take to loop or re-transcribe; with nothing to play
        // there is nothing to mark (loop design §5; it was `.populated` only before the loop).
        if !newState.canPlay, editor.range != nil {
            editor.range = nil
        }

        // The selection is fixed once a transcription exists, and the "+" goes away with it. A
        // picker left open over that would be offering a choice that no longer applies.
        if newState.hasTranscription, isInstrumentMenuOpen {
            isInstrumentMenuOpen = false
        }
    }

    /// The tab switch (⌘1, ⌘2, ⌘3, the tab strip): Edit and Score only with a finished
    /// transcription. Beside ``workspace`` because its setter is this file's.
    func setWorkspace(_ workspace: Workspace) {
        guard workspace != self.workspace else { return }
        guard workspace == .transcribe || canEdit else { return }

        _ = dragCanceller?()
        self.workspace = workspace
    }

    // MARK: - Instrument selection and mix

    /// The instrument groups to restrict the next run to, in enumerator order. Empty means
    /// Automatic: the model chooses. Whoever sets it passes a list through
    /// ``normalised(_:)`` first; the commands below do.
    var selectedGroups: [InstrumentGroup] = [] {
        didSet { refreshMixerEntries() }
    }

    // Internal setter: written from AppModel+Mix.swift.
    var mixer = InstrumentMixerState()

    // MARK: - Transport

    /// Mirrors the engine, refreshed by the display-link tick and on every transport command.
    // Internal setter: AppModel+Loading.swift and AppModel+Playback.swift write it.
    var isPlaying: Bool = false

    /// Mirrors the engine, refreshed by the display-link tick and on every transport command.
    // Internal setter: AppModel+Loading.swift and AppModel+Playback.swift write it.
    var playheadSeconds: Double = 0

    /// Bumped by ``goToStart()``, so the timeline can scroll to its left edge (§5.1) even when the
    /// playhead was already at 0.
    // Internal setter: written from AppModel+Playback.swift.
    var goToStartGeneration = 0

    var followPlayhead: Bool = true

    /// The Loop button: playback repeats the marked range, or the whole take without one (loop
    /// design §5). Transient, like the range. `AppModel+Practice.swift` is its only writer.
    var loopEnabled = false

    /// The taps in flight for the Tap button and the `t` key (tempo design §4).
    /// `AppModel+Tempo.swift` is its only user.
    @ObservationIgnored var tapTempo = TapTempo()

    /// True while a tempo detection runs off the main thread; the Detect button dims.
    var isDetectingTempo = false

    /// The SPEED pill: how fast the take plays, its pitch unchanged, the MIDI on the same clock
    /// (speed design §5). 1 is the take's own. Transient, like the loop. Clamped to
    /// ``speedRange``.
    var playbackSpeed: Double = 1 {
        didSet {
            let clamped = playbackSpeed.isFinite
                ? min(max(playbackSpeed, AppModel.speedRange.lowerBound), AppModel.speedRange.upperBound) : 1

            if clamped != playbackSpeed {
                playbackSpeed = clamped
            }

            engine.speed = clamped
        }
    }

    /// The MUTE button. In the original this cleared the input pass-through before the player ran;
    /// the standalone never routes the input to the output, so here it mutes the app's own output
    /// (spec §7 deviation 2): the master fader goes to silence while it is on. Never persisted, as
    /// the original's standalone never stored it.
    var inputMuted: Bool = false {
        didSet { engine.muted = inputMuted }
    }

    /// The equal-power crossfade, 0 = source only, 1 = synth only (§5.3).
    var mix: Double = 0.5 {
        didSet { engine.mix = engineMix }
    }

    /// The source in the left ear and the synth in the right, nothing mixed (ours): the slider is
    /// inert while it is on, the ORIG / MIDI holds still silence the other ear. Not in the project
    /// file, like the mix itself.
    var stereoSplit = false {
        didSet {
            engine.stereoSplit = stereoSplit
            engine.mix = engineMix
        }
    }

    /// A crossfade held in place of ``mix`` for as long as the master panel's ORIG or MIDI label
    /// is pressed, to hear one side alone; nil otherwise. Never written to ``mix``, so letting go
    /// puts back exactly what was set.
    // Internal setter: written from AppModel+Mix.swift.
    var mixHold: Double?

    /// The master fader, −36 (silence) … +6 dB.
    var masterGainDb: Double = 0 {
        didSet { engine.masterGainDb = masterGainDb }
    }

    /// The master panel's CLICK and `k`: the metronome on the grid's beats during playback
    /// (click design §2). Per project; `AppModel+Click.swift` pushes it to the engine.
    var clickEnabled = false {
        didSet { applyClickEnabled() }
    }

    /// The click's fader, −36 (silence) … +6 dB. Per project.
    var clickGainDb: Double = ProjectState.defaultClickGainDb {
        didSet { engine.synthBank.setClickGain(db: clickGainDb) }
    }

    /// The beats still to come in the count-in, as the status bar shows them ("Count-in · 3"),
    /// or nil when there is no count-in. `AppModel+Click.swift` is its only writer.
    var countInRemaining: Int?

    /// When each beat of the count-in in progress falls on the click's clock, for that count.
    @ObservationIgnored var countInBeats: [Double] = []

    /// A sound bank that could not be loaded before a window could say so; shown once one can
    /// (`AppModel+SoundBank.swift`).
    @ObservationIgnored var pendingSoundBankFailure: String?

    // MARK: - Zoom

    var zoomLevel: Double = 1

    /// The vertical zoom, or −1 for automatic (fit the transcription's octaves).
    var verticalZoom: Double = -1

    /// What an automatic vertical zoom (`verticalZoom < 0`) resolves to: the norm that fits the
    /// transcription's octaves in the piano roll's height. The timeline writes it whenever it
    /// re-fits, since only it knows its height; the status bar's slider reads it.
    var fittedVerticalZoom: Double = 0

    // MARK: - Export and settings

    /// The project tempo: the grid's BPM and the tempo the MIDI file is written at.
    var exportTempo: Double {
        get { editor.grid.bpm }
        set { editor.grid.bpm = TempoGrid.clampedBpm(newValue) }
    }

    var settings: GlobalSettings {
        didSet {
            // The MIDI output's channels follow the export's overflow mode (MIDI out design §2).
            if settings.midiOverflowMode != oldValue.midiOverflowMode { refreshMidiRoutes() }
        }
    }

    /// Audio → MIDI Output's list, re-read when the menu opens and when CoreMIDI's setup changes,
    /// and the destination the notes are going to, nil for None (`AppModel+MidiOut.swift`).
    var midiDestinations: [MidiDestination] = []
    var midiOutDestination: MidiDestination?

    // MARK: - Project

    /// Where the project is saved, or nil for an untitled one. Only `AppModel+Project.swift`
    /// writes it.
    var projectURL: URL?

    /// Content differs from what was last saved: the dot in the close button. Kept by
    /// `ProjectTracker`; the commands that need the truth now call ``computeProjectEdited()``.
    var isProjectEdited = false

    /// What the last save (or the empty project) held; the dirty rule compares against it.
    @ObservationIgnored var lastSavedContent: ProjectContent?

    /// ``sourceGeneration`` as of the last save: a different value means the audio changed.
    @ObservationIgnored var lastSavedSourceGeneration = 0

    /// The audio's name inside the saved package, for the unchanged-audio copy on the next save.
    @ObservationIgnored var lastSavedAudioFileName = ""

    /// Installed by the welcome view and the main view: shows the project window (and dismisses
    /// the welcome window), and the reverse. Nil before a window exists.
    @ObservationIgnored var showProjectWindow: (() -> Void)?
    @ObservationIgnored var showWelcomeWindow: (() -> Void)?

    /// A file the Finder asked to open before a window could show an error for it; the main
    /// view opens it once the dialogs are installed.
    @ObservationIgnored var pendingOpenURL: URL?

    // MARK: - Models

    /// Re-scanned at 10 Hz by ``modelPollTimer`` and whenever a download changes phase.
    // Internal setter: written from AppModel+Models.swift.
    var installedModels: Set<ModelSize> = []

    // Internal setter: written from AppModel+Models.swift.
    var downloadPhases: [ModelSize: DownloadPhase] = [:]

    /// The Settings window's tab. Set before opening the window to land on a particular one.
    var settingsTab: SettingsTab = .general

    /// File → Export MIDI…: the sheet that asks for the export settings before the save panel.
    var isExportDialogPresented = false

    // Internal: written from AppModel+Models.swift.
    @ObservationIgnored var modelPollTimer: Timer?

    var isInstrumentMenuOpen: Bool = false

    // MARK: - Updates

    /// The Sparkle updater; the menu item follows its ``Updates/canCheckForUpdates``.
    let updates = Updates()

    // MARK: - Audio failures

    /// Set once the launch's start failure has been shown, so a view appearing twice does not
    /// show it twice.
    // Internal: written from AppModel+Devices.swift.
    @ObservationIgnored var hasReportedLaunchStartFailure = false

    /// The device input that was in effect before System Audio or an app was chosen, nil for the
    /// system default: where a refused permission or a quit app sends the input back to (system
    /// audio design §2).
    @ObservationIgnored var lastDeviceInput: AudioDevice?

    /// Which take the tap-start check belongs to, so a check from an earlier take does nothing.
    @ObservationIgnored var tapStartGeneration = 0

    // MARK: - Meters

    /// The master meter after ballistics and the staleness rule (§2.5).
    private(set) var masterLevelDb: Double = MeterScale.minDb

    /// Per-program levels after ballistics, for every instrument in the mix.
    // Internal: AppModel+Loading.swift's resetTranscription empties it.
    var instrumentLevels: [Int: Double] = [:]

    @ObservationIgnored private var masterBallistics = MeterBallistics()
    // Internal: AppModel+Loading.swift's resetTranscription empties it.
    @ObservationIgnored var instrumentBallistics: [Int: MeterBallistics] = [:]

    /// The render counter as of the last tick, and how long it has stood still.
    @ObservationIgnored private var lastRenderedFrames: UInt64 = 0
    @ObservationIgnored private var renderStaleSeconds = 0.0

    // MARK: - Init

    init(paths: AppPaths = .standard) {
        self.paths = paths
        engine = PlaybackEngine()
        recorder = Recorder(engine: engine, paths: paths)
        transcriber = TranscriptionEngine()
        modelStore = ModelStore(paths: paths)
        downloader = ModelDownloader(paths: paths)
        settings = GlobalSettings.load(from: paths.globalSettings)

        try? paths.ensureDirectories()
        modelStore.deleteStalePartFiles()

        // The autosaved session is gone with projects; its files and any take a crash left behind
        // go at launch.
        paths.deleteLegacySessionFiles()
        paths.sweepRecordings()

        installedModels = modelStore.installed()
        lastRenderedFrames = engine.synthBank.renderedFrames

        engine.mix = effectiveMix
        engine.masterGainDb = masterGainDb
        engine.muted = inputMuted

        engine.onPlayheadWrapped = { [weak self] in
            self?.handlePlayheadWrapped()
        }

        // The count-in's state machine runs off the engine's own poll (click design §2).
        engine.onPoll = { [weak self] in
            self?.pollCountIn()
        }

        engine.synthBank.setClickGain(db: clickGainDb)
        applySoundBankSetting()

        // The remembered MIDI destination, if it is there (MIDI out design §2).
        startMidiOut()

        // The app a take is tapping quit: the take ends with what it has (system audio design §2).
        engine.onTappedProcessExited = { [weak self] in
            self?.handleTappedAppQuit()
        }

        // Before the engine starts, so it starts on the remembered input's devices.
        restoreRecordingInput()

        // Eight rebuilds, backed off, and still nothing: said so, and said again if the next
        // budget -- Play, or a device pick -- runs out the same way.
        engine.onHealExhausted = { [weak self] in
            self?.presentAudioStartFailure()
        }

        // An arbitrary queue: re-read on the main actor rather than trusting the delivered phase,
        // so two hops landing out of order cannot leave a stale one showing.
        downloader.onChange = { @Sendable [weak self] size, _ in
            guard let self else { return }

            Task { @MainActor in
                self.refreshDownloadPhase(size)
            }
        }

        // A refusal here leaves the engine's own health check retrying with its backoff; the error
        // stays in `lastStartError` and is shown once the window can show it
        // (``presentAudioStartFailureIfAny()``).
        try? engine.start()

        startModelPoll()

        // A fresh project is clean: nothing to compare against yet but the empty state itself.
        markProjectSaved(audioFileName: "")
    }

    // MARK: - Derived

    /// Record starts a take from empty, and stops one in progress or cancels its count-in.
    var canRecord: Bool { (state == .empty && importJob == nil) || state == .recording || state == .countingIn }

    var canTranscribe: Bool {
        state == .audioLoaded && modelSize != nil && !jobActive && importJob == nil && stemsExport == nil
    }

    /// Both MIDI exits: only a finished transcription, never a half-decoded one (§6.1).
    var canExport: Bool { state == .populated }

    /// Names the selection only once there is audio to run it on (`_layOutTranscribeButton`):
    /// with nothing loaded there is nothing to be specific about, so it names the action only.
    var transcribeLabel: String {
        switch state == .audioLoaded ? selectedGroups.count : 0 {
        case 0: String(localized: "Transcribe", comment: "The roll's call to action with no instruments chosen")
        case let n: String(localized: "Transcribe \(n) instruments", comment: "The roll's call to action, with how many instruments are chosen")
        }
    }

    var timeReadout: (position: String, total: String) {
        (TimeFormat.transport(playheadSeconds),
         duration > 0 ? TimeFormat.transport(duration) : TimeFormat.transportPlaceholder)
    }

    /// What the status bar counts. The range is nil until there is a note to range over, so a
    /// placeholder strip does not read as "C-1 - C-1" (§1.7).
    var statusLine: (instruments: Int, notes: Int, lowest: Int?, highest: Int?) {
        let populated = mixer.entries.filter { $0.noteCount > 0 }
        let lowest = populated.map(\.lowestPitch).min()
        let highest = populated.map(\.highestPitch).max()

        return (mixer.entries.count, notes.count, lowest, highest)
    }

    // MARK: - MIDI

    /// The file bytes, or nil unless the transcription is finished (§6.1).
    func midiData() -> Data? {
        guard canExport else { return nil }

        // Through the tempo map: a tempo and a meter at each change (tempo map design §2).
        // The section markers in the conductor track (markers and lyrics design §2).
        // Each track's pan as CC 10 (click design §2).
        let pans = mixer.settings.mapValues(\.pan)

        return MidiFileWriter.data(notes: notes, grid: editor.grid, mode: settings.midiOverflowMode, markers: editor.markers,
                                   pans: pans)
    }

    /// `<source>_NNTranscription.mid`, or `NNTranscription.mid` for a recorded take.
    func midiExportFileName() -> String {
        MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// File → Export MIDI…: the dialog, which then calls ``exportMidi()``.
    func requestExport() {
        guard canExport else { return }

        isExportDialogPresented = true
    }

    /// The export dialog's Export…: a save panel titled "Export MIDI" in the Music folder, `.mid`
    /// only, the overwrite warning left on (§6.1).
    func exportMidi() {
        guard let data = midiData() else { return }

        let panel = NSSavePanel()
        // `message` is what the modern panel shows; `title` is kept for the accessibility name.
        panel.title = String(localized: "Export MIDI", comment: "File → Export MIDI…'s save panel")
        panel.message = String(localized: "Export MIDI", comment: "File → Export MIDI…'s save panel")
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = midiExportFileName()
        panel.allowedContentTypes = [.midi]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(AppModel.errorTitle, String(localized: "Could not write the MIDI file.", comment: "Alert body: File → Export MIDI… failed"))
        }
    }

    // MARK: - MusicXML

    /// The score as bytes, or nil unless the transcription is finished (MusicXML design §4):
    /// the notes quantized to the grid, the parts as the arrangement shows them, titled after
    /// the sheet or the take, with the chord symbols as harmony (chord symbols design §2) and the
    /// markers as rehearsal marks (markers and lyrics design §2).
    func musicXMLData() -> Data? {
        guard canExport else { return nil }

        return MusicXMLWriter.data(notes: notes, ids: document?.notes.map { Optional($0.id) }, grid: editor.grid,
                                   key: editor.key, arrangement: arrangement, takeName: droppedFileName,
                                   chords: editor.chords, markers: editor.markers)
    }

    /// `<source>_NNTranscription.musicxml`, or `NNTranscription.musicxml` for a recorded take.
    func musicXMLExportFileName() -> String {
        MusicXMLWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// File → Export MusicXML…: a save panel titled "Export MusicXML" in the Music folder, the
    /// MIDI exit's shape. No dialog: the tempo and the division are the Edit toolbar's.
    func exportMusicXML() {
        guard let data = musicXMLData() else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export MusicXML", comment: "File → Export MusicXML…'s save panel")
        panel.message = String(localized: "Export MusicXML", comment: "File → Export MusicXML…'s save panel")
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = musicXMLExportFileName()
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError(AppModel.errorTitle, String(localized: "Could not write the MusicXML file.", comment: "Alert body: File → Export MusicXML… failed"))
        }
    }

    // MARK: - Updates

    /// Check for Updates…, from the app menu and Settings. Sparkle shows the result itself,
    /// including "You're up to date"; there is nothing to say in the status bar any more.
    func checkForUpdates() {
        updates.check()
    }

    // MARK: - Zoom

    /// View → Reset Zoom: horizontal back to 1, vertical back to automatic (§11.3).
    func resetZoom() {
        zoomLevel = 1
        verticalZoom = -1
    }

    // MARK: - Meters

    /// One instrument's level after ballistics, or the floor for a program not in the mix.
    func instrumentLevelDb(program: Int) -> Double {
        instrumentLevels[program] ?? MeterScale.minDb
    }

    /// Instant attack, 24 dB/s release, every meter fed the floor once the render thread has
    /// stood still for `max(0.5 s, 2 × block)` so a stopped engine's meters fall rather than
    /// stick (§2.5).
    // Internal: called from AppModel+Playback.swift's displayLinkTick.
    func advanceMeters(dt: Double) {
        let frames = engine.synthBank.renderedFrames

        if frames != lastRenderedFrames {
            lastRenderedFrames = frames
            renderStaleSeconds = 0
        } else {
            renderStaleSeconds += max(0, dt)
        }

        let blockSeconds = engine.sampleRate > 0 ? Double(engine.ioBufferFrames) / engine.sampleRate : 0
        let stale = renderStaleSeconds >= max(0.5, 2 * blockSeconds)

        let master = masterBallistics.advance(input: stale ? MeterScale.minDb : engine.masterLevelDb, dt: dt)

        if master != masterLevelDb {
            masterLevelDb = master
        }

        // In place, keyed by what is in the mix now: a program that left the mix is pruned, and
        // the published dictionary is written only for a level that actually moved.
        for entry in mixer.entries {
            let program = entry.program
            let input = stale ? MeterScale.minDb : engine.synthBank.levelDb(program: program)
            let level = instrumentBallistics[program, default: MeterBallistics()].advance(input: input, dt: dt)

            if instrumentLevels[program] != level {
                instrumentLevels[program] = level
            }
        }

        if instrumentBallistics.count != mixer.entries.count {
            let present = Set(mixer.entries.map(\.program))

            for program in instrumentBallistics.keys where !present.contains(program) {
                instrumentBallistics[program] = nil
                instrumentLevels[program] = nil
            }
        }
    }

    // MARK: - Timers

    /// A repeating main-run-loop timer whose body runs on the main actor, in `.common` mode so it
    /// keeps ticking through a menu or a drag.
    static func repeatingTimer(hz: Double, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: 1.0 / hz, repeats: true) { _ in
            MainActor.assumeIsolated(body)
        }

        RunLoop.main.add(timer, forMode: .common)

        return timer
    }
}
