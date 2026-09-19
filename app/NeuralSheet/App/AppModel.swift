import AVFoundation
import AppKit
import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The update-check notice, once one is showing (inventory §9). Task 20's `UpdateCheck` sets it;
/// ``AppModel/displayLinkTick(dt:)`` drops it at `expiresAt`, and the hovering view pushes
/// `expiresAt` out while the pointer is over it.
nonisolated struct UpdateNotice: Equatable, Sendable {
    var text: String
    var showsSeeUpdate: Bool
    var expiresAt: Date
}

/// The one main-actor object every view reads and every command goes through: the §11.1 state
/// machine, what audio is loaded, the transcription as it streams in, the mix, the transport, the
/// model panel and the update notice.
///
/// Everything here is the main actor's. The engine, the recorder and the downloader call back on
/// their own threads and are hopped onto the main actor before they touch anything of this
/// object's; the transcription's per-chunk notes go through ``TranscriptionStaging`` and a 30 Hz
/// drain (`AppModel+Transcription.swift`), the way the C++ `TranscriptionManager` did it.
///
/// Persistence is Task 20's: the settings are read once here so the model resolves correctly on
/// its own, but nothing writes them back yet.
@MainActor @Observable final class AppModel {
    // MARK: - Dependencies

    let paths: AppPaths
    let engine: PlaybackEngine
    let recorder: Recorder
    let transcriber: TranscriptionEngine
    let modelStore: ModelStore
    let downloader: ModelDownloader

    // MARK: - Dialogs

    /// Installed by the view layer: `(title, body)` for every §11.7 message box. Nil drops the
    /// message, which is what happens before a window exists.
    @ObservationIgnored var presentError: ((String, String) -> Void)?

    /// Installed by the view layer: `(title, body, confirm button title, completion)`. Nil
    /// confirms at once, which is what happens before a window exists.
    @ObservationIgnored var presentConfirm: ((String, String, String, @escaping (Bool) -> Void) -> Void)?

    /// Cancels the roll drag in progress, if the roll has one; installed by the edit controller.
    @ObservationIgnored var dragCanceller: (() -> Void)?

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
    private(set) var source: SourceAudio?

    /// Seconds of audio: 0 when there is none, growing live while recording (refreshed by the
    /// display-link tick), `source.duration` otherwise.
    private(set) var duration: Double = 0

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

    /// The editable transcription: nil until a run completes or a session restores one. Once it
    /// exists, `transcription.notes` is always `document.events` (`AppModel+Editing.swift`).
    var document: NoteDocument?

    /// The editor's tool, selection, target instrument, snap and grid.
    var editor = EditorState()

    /// The one place the state changes. The pipeline's and the commands'; views never call it.
    func transition(to newState: AppState) {
        guard newState != state else { return }

        state = newState

        // The Edit tab is only for a finished transcription.
        if newState != .populated, workspace != .transcribe {
            workspace = .transcribe
        }

        // The selection is fixed once a transcription exists, and the "+" goes away with it. A
        // picker left open over that would be offering a choice that no longer applies.
        if newState.hasTranscription, isInstrumentMenuOpen {
            isInstrumentMenuOpen = false
        }
    }

    /// The tab switch (⌘1, ⌘2, the segmented control): Edit only with a finished transcription.
    /// Beside ``workspace`` because its setter is this file's.
    func setWorkspace(_ workspace: Workspace) {
        guard workspace != self.workspace else { return }
        guard workspace == .transcribe || canEdit else { return }

        dragCanceller?()
        self.workspace = workspace
    }

    /// §3.4 step 6, and nowhere else: the next run's instruments start neutral. A session reload
    /// keeps its mix (§4.2).
    func resetMixerSettingsForLaunch() {
        mixer.resetStoredSettings()
        refreshMixerEntries()
    }

    // MARK: - Instrument selection and mix

    /// The instrument groups to restrict the next run to, in enumerator order. Empty means
    /// Automatic: the model chooses. Whoever sets it passes a list through
    /// ``normalised(_:)`` first; the commands below do.
    var selectedGroups: [InstrumentGroup] = [] {
        didSet { refreshMixerEntries() }
    }

    /// The programs the selection stands for, which the sidebar shows as placeholders (§3.3).
    var selectedPrograms: [Int] { selectedGroups.map(Instruments.program(for:)) }

    private(set) var mixer = InstrumentMixerState()

    // MARK: - Transport

    /// Mirrors the engine, refreshed by the display-link tick and on every transport command.
    private(set) var isPlaying: Bool = false

    /// Mirrors the engine, refreshed by the display-link tick and on every transport command.
    private(set) var playheadSeconds: Double = 0

    /// Bumped by ``goToStart()``, so the timeline can scroll to its left edge (§5.1) even when the
    /// playhead was already at 0.
    private(set) var goToStartGeneration = 0

    var followPlayhead: Bool = true

    /// The MUTE button. In the original this cleared the input pass-through before the player ran;
    /// the standalone never routes the input to the output, so here it mutes the app's own output
    /// (spec §7 deviation 2): the master fader goes to silence while it is on. Never persisted, as
    /// the original's standalone never stored it.
    var inputMuted: Bool = false {
        didSet { engine.muted = inputMuted }
    }

    /// The equal-power crossfade, 0 = source only, 1 = synth only (§5.3).
    var mix: Double = 0.5 {
        didSet { engine.mix = effectiveMix }
    }

    /// A crossfade held in place of ``mix`` for as long as the top bar's ORIG or MIDI label is
    /// pressed, to hear one side alone; nil otherwise. Never written to ``mix``, so letting go
    /// puts back exactly what was set.
    private(set) var mixHold: Double?

    /// What the engine plays: the hold while there is one, the set mix otherwise.
    var effectiveMix: Double { mixHold ?? mix }

    enum MixSide {
        case source
        case synth
    }

    /// Mouse-down on ORIG or MIDI: that side alone until ``endMixHold()``.
    func beginMixHold(_ side: MixSide) {
        mixHold = side == .source ? 0 : 1
        engine.mix = effectiveMix
    }

    func endMixHold() {
        guard mixHold != nil else { return }

        mixHold = nil
        engine.mix = effectiveMix
    }

    /// The master fader, −36 (silence) … +6 dB.
    var masterGainDb: Double = 0 {
        didSet { engine.masterGainDb = masterGainDb }
    }

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

    var settings: GlobalSettings

    // MARK: - Models

    /// The size a run would use: the preference when installed, else Medium, else the first
    /// installed size, else nil (nothing to transcribe with). The same rule as `ModelStore.resolve`,
    /// read off ``installedModels`` so it is observable.
    var modelSize: ModelSize? {
        if installedModels.contains(settings.modelSize) {
            return settings.modelSize
        }

        if installedModels.contains(ModelManifest.defaultSize) {
            return ModelManifest.defaultSize
        }

        return ModelSize.allCases.first(where: installedModels.contains)
    }

    /// Re-scanned at 10 Hz by ``modelPollTimer`` and whenever a download changes phase.
    private(set) var installedModels: Set<ModelSize> = []

    private(set) var downloadPhases: [ModelSize: DownloadPhase] = [:]

    /// No model installed and nothing else to do on the roll: the roll says so, and points at
    /// Settings (§3.2).
    var needsModelNotice: Bool {
        installedModels.isEmpty && (state == .empty || state == .audioLoaded)
    }

    /// The Settings window's tab. Set before opening the window to land on a particular one.
    var settingsTab: SettingsTab = .general

    /// File → Export MIDI…: the sheet that asks for the export settings before the save panel.
    var isExportDialogPresented = false

    @ObservationIgnored private var modelPollTimer: Timer?

    var isInstrumentMenuOpen: Bool = false

    // MARK: - Update check

    var updateNotice: UpdateNotice?

    // MARK: - Audio failures

    /// Set once the launch's start failure has been shown, so a view appearing twice does not
    /// show it twice.
    @ObservationIgnored private var hasReportedLaunchStartFailure = false

    // MARK: - Meters

    /// The master meter after ballistics and the staleness rule (§2.5).
    private(set) var masterLevelDb: Double = MeterScale.minDb

    /// Per-program levels after ballistics, for every instrument in the mix.
    private var instrumentLevels: [Int: Double] = [:]

    @ObservationIgnored private var masterBallistics = MeterBallistics()
    @ObservationIgnored private var instrumentBallistics: [Int: MeterBallistics] = [:]

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
        installedModels = modelStore.installed()
        lastRenderedFrames = engine.synthBank.renderedFrames

        engine.mix = effectiveMix
        engine.masterGainDb = masterGainDb
        engine.muted = inputMuted

        engine.onPlayheadWrapped = { [weak self] in
            self?.handlePlayheadWrapped()
        }

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
    }

    // MARK: - Derived

    var canRecord: Bool { state == .empty || state == .recording }

    var canTranscribe: Bool { state == .audioLoaded && modelSize != nil && !jobActive }

    /// Both MIDI exits: only a finished transcription, never a half-decoded one (§6.1).
    var canExport: Bool { state == .populated }

    /// Names the selection only once there is audio to run it on (`_layOutTranscribeButton`):
    /// with nothing loaded there is nothing to be specific about, so it names the action only.
    var transcribeLabel: String {
        switch state == .audioLoaded ? selectedGroups.count : 0 {
        case 0: "Transcribe"
        case 1: "Transcribe 1 instrument"
        case let n: "Transcribe \(n) instruments"
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

    // MARK: - Recording

    /// The Record toggle: starts a take from empty, stops the one in progress. Anything else is
    /// not the button's to do.
    func toggleRecord() {
        switch state {
        case .empty:
            switch Recorder.microphoneAuthorization {
            case .authorized:
                startRecording()

            case .notDetermined:
                // The prompt stands for as long as the user leaves it; `start()` never waits on it.
                Recorder.requestMicrophoneAccess { [weak self] granted in
                    MainActor.assumeIsolated {
                        guard let self, self.state == .empty else { return }

                        if granted {
                            self.startRecording()
                        } else {
                            self.presentMicrophoneDenied()
                        }
                    }
                }

            default:
                presentMicrophoneDenied()
            }

        case .recording:
            stopRecording()

        case .audioLoaded, .processing, .populated:
            return
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
        } catch Recorder.RecordError.permissionDenied {
            presentMicrophoneDenied()
            return
        } catch {
            clear()
            showError("Error", "File creation for recording failed.")
            return
        }

        duration = 0
        transition(to: .recording)
    }

    private func stopRecording() {
        guard let take = recorder.stop() else {
            // Nothing captured is not a failure; a take that could not be written or read back is.
            if let error = recorder.lastError {
                presentRecordingFailure(error)
            }

            clear()
            return
        }

        install(take)
    }

    private func presentRecordingFailure(_ error: Recorder.RecordError) {
        switch error {
        case .fileCreation:
            showError("Error", "File creation for recording failed.")
        case .readBack, .writeFailed:
            showError("Could not load the recorded audio sample.", "")
        case .permissionDenied:
            presentMicrophoneDenied()
        }
    }

    private func presentMicrophoneDenied() {
        showError(
            "Error",
            "Microphone access has not been granted. Allow NeuralSheet to use the microphone in "
                + "System Settings › Privacy & Security › Microphone.")
    }

    // MARK: - Loading

    /// Loads a dropped or chosen file, replacing whatever was there (§2.2). Not while recording
    /// or transcribing. Edited notes are asked about first, as any clear does (design §3.5), and
    /// the load waits on the answer.
    func loadAudio(url: URL) {
        guard state == .empty || state == .audioLoaded || state == .populated else { return }

        // Before anything is cleared: the C++ drop target refuses an unknown extension ahead of
        // `onFileDrop`, so a stray .txt on a finished transcription costs nothing.
        guard AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            let accepted = AudioFileLoader.acceptedExtensions.map { ".\($0)" }.joined(separator: ", ")
            showError("Could not load the file.", "Check your file format (Accepted formats: \(accepted)).")
            return
        }

        confirmDiscardingEdits(action: "Loading another file") { [weak self] in
            guard let self else { return }

            clearNow()
            load(url: url, restoringSession: false)
        }
    }

    /// A session's take, re-read from its path (§8.2): the file a session was working on, whether
    /// the user's own or a recording in `paths.recordings`. A recording restored this way shows no
    /// file name -- it was never a dropped file -- and is deleted on clear as any take is.
    ///
    /// Only from `empty`, and a path that no longer exists is skipped in silence: a session whose
    /// file has gone is an empty session, not an error.
    func restoreAudio(url: URL) {
        guard state == .empty, FileManager.default.fileExists(atPath: url.path) else { return }

        load(url: url, restoringSession: true)
    }

    private func load(url: URL, restoringSession: Bool) {
        let audio: SourceAudio

        do {
            // A restored recording was never a dropped file, so it carries no name.
            audio = try AudioFileLoader.load(url: url,
                                             deviceRate: engine.sampleRate,
                                             namedAfterFile: !(restoringSession && isDeletableRecording(url)))
        } catch {
            showError(
                "Could not load the audio file.",
                "Check your file format (Accepted formats: .wav, .aiff, .flac, .mp3, .ogg).")
            return
        }

        install(audio)
    }

    /// Hands a take to the engine and moves to `audioLoaded`.
    private func install(_ audio: SourceAudio) {
        source = audio
        duration = audio.duration
        engine.setSource(audio)
        playheadSeconds = 0
        isPlaying = false
        transition(to: .audioLoaded)
    }

    // MARK: - Clearing

    /// Audio and transcription both (§2.6). Refused while a run is in flight: the drain owns the
    /// notes until the engine's completion lands, and cancelling is the way out of that. Edited
    /// notes are asked about first (design §3.5).
    func clear() {
        guard !jobActive else { return }

        confirmDiscardingEdits(action: "Clearing") { [weak self] in
            self?.clearNow()
        }
    }

    /// `clear()` past the question: the pipeline's, for a take too short to run.
    func clearNow() {
        if state == .recording {
            // The take is discarded whatever came of it; the files go below.
            _ = recorder.stop()
        }

        resetTranscription()
        engine.setSource(nil)
        deleteRecordedFiles()

        source = nil
        duration = 0
        transition(to: .empty)
    }

    /// The transcription only, keeping the audio (§2.6).
    func clearTranscription() {
        guard !jobActive else { return }

        confirmDiscardingEdits(action: "Clearing") { [weak self] in
            self?.clearTranscriptionNow()
        }
    }

    /// `clearTranscription()` past the question: the pipeline's, for a run that ended without a
    /// result and so has no edits to protect.
    func clearTranscriptionNow() {
        resetTranscription()
        transition(to: source != nil ? .audioLoaded : .empty)
    }

    /// What both clears share: the notes, the document, the synths, the transport. The mixer's
    /// stored settings survive — they are dropped at launch and nowhere else (§4.2).
    private func resetTranscription() {
        engine.stop()

        transcription = TranscriptionState()
        staging.reset()
        document = nil
        editor.selection = []
        dragCanceller?()

        // Otherwise the synth keeps playing the notes of the transcription just thrown away.
        engine.synthBank.scheduler.swap(notes: [])
        engine.synthBank.reset()
        engine.refreshGains()

        refreshMixerEntries()
        instrumentLevels = [:]
        instrumentBallistics = [:]

        playheadSeconds = 0
        isPlaying = false
    }

    /// Deletes the files a recorded take left behind: only ever files inside `paths.recordings`
    /// whose name starts with the recording prefix (§2.6), so a dropped file is never touched.
    private func deleteRecordedFiles() {
        var candidates: [URL] = []

        if let native = source?.sourcePath {
            candidates.append(native)
            candidates.append(AppModel.downsampledSibling(of: native))
        }

        if let native = recorder.nativeFileURL {
            candidates.append(native)
        }

        if let downsampled = recorder.downsampledFileURL {
            candidates.append(downsampled)
        }

        for url in candidates where isDeletableRecording(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isDeletableRecording(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        let recordings = paths.recordings.standardizedFileURL.path

        return directory == recordings && url.lastPathComponent.hasPrefix(Recorder.filenamePrefix)
    }

    /// `recorded_audio<stamp>.wav` → `recorded_audio<stamp>_downsampled.wav`.
    private static func downsampledSibling(of native: URL) -> URL {
        let stem = native.deletingPathExtension().lastPathComponent

        return native.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_downsampled")
            .appendingPathExtension(native.pathExtension)
    }

    // MARK: - Transport

    func togglePlay() {
        guard state.canPlay else { return }

        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }

        syncTransport()
    }

    /// Stop and rewind (§5.1). The timeline follows ``goToStartGeneration`` back to its left edge.
    func goToStart() {
        guard state.canPlay else { return }

        engine.stop()
        syncTransport()
        goToStartGeneration &+= 1
    }

    /// Ignored unless `0 <= seconds < duration`, as the engine has it.
    func seek(toSeconds seconds: Double) {
        guard state.canPlay else { return }

        engine.seek(seconds: seconds)
        syncTransport()
    }

    private func handlePlayheadWrapped() {
        // The engine has already stopped and rewound.
        syncTransport()
    }

    // MARK: - Audio devices

    /// What the Audio menu shows as chosen: the engine's own, which it rolls back when a device
    /// refuses, so the menu re-reads these after every pick.
    var inputDevice: AudioDevice? { engine.inputDevice }
    var outputDevice: AudioDevice? { engine.outputDevice }

    /// The Audio menu's Input pick, applied at once (spec §7 deviation 7). A device the engine
    /// could not use is rolled back and said so.
    func setInputDevice(_ device: AudioDevice?) {
        guard device != engine.inputDevice else { return }

        engine.inputDevice = device
        reportDeviceSwitch()
    }

    /// The Audio menu's Output pick, as ``setInputDevice(_:)``.
    func setOutputDevice(_ device: AudioDevice?) {
        guard device != engine.outputDevice else { return }

        engine.outputDevice = device
        reportDeviceSwitch()
    }

    /// The pick rebuilt the graph and, when the engine was not running, was its retry: a device
    /// that refused is one dialog, an output that then would not start is the other.
    private func reportDeviceSwitch() {
        if let status = engine.lastDeviceError {
            showError("Audio device could not be used", "CoreAudio error \(PlaybackEngine.describe(status)).")
        } else if !engine.isRunning, engine.lastStartError != nil {
            presentAudioStartFailure()
        }
    }

    /// Once, when the window can show a dialog: a launch whose output would not open -- and that
    /// the health check has not opened since -- is said so. Its retries carry on underneath.
    func presentAudioStartFailureIfAny() {
        guard !hasReportedLaunchStartFailure, !engine.isRunning,
              engine.lastStartError != nil || engine.healExhausted
        else { return }

        hasReportedLaunchStartFailure = true
        presentAudioStartFailure()
    }

    /// "Audio could not start", with what CoreAudio said. Not before a window exists: the launch
    /// path picks it up in ``presentAudioStartFailureIfAny()`` instead.
    private func presentAudioStartFailure() {
        guard presentError != nil else { return }

        let detail = engine.lastStartError.map { PlaybackEngine.describe($0) + "." }
            ?? "The audio output did not start."

        showError("Audio could not start", detail)
    }

    private func syncTransport() {
        let playing = engine.isPlaying
        let position = engine.playheadSeconds

        if playing != isPlaying {
            isPlaying = playing
        }

        if position != playheadSeconds {
            playheadSeconds = position
        }
    }

    // MARK: - Instrument selection

    /// Adds or removes one group. Only before a run: the selection is a decoder constraint, not
    /// a filter, so it cannot change once a transcription exists (§3.3).
    func setSelected(_ group: InstrumentGroup, _ on: Bool) {
        guard !state.hasTranscription else { return }

        var groups = selectedGroups

        if on {
            groups.append(group)
        } else {
            groups.removeAll { $0 == group }
        }

        let normalised = AppModel.normalised(groups)

        if normalised != selectedGroups {
            selectedGroups = normalised
        }
    }

    /// Back to Automatic.
    func clearSelection() {
        guard !state.hasTranscription, !selectedGroups.isEmpty else { return }

        selectedGroups = []
    }

    /// Enumerator order, duplicates dropped: the only shape ``selectedGroups`` is set to.
    static func normalised(_ groups: [InstrumentGroup]) -> [InstrumentGroup] {
        let chosen = Set(groups)

        return InstrumentGroup.allCases.filter(chosen.contains)
    }

    /// Re-derives the sidebar's rows from the notes and the selection, and pushes the faders.
    func refreshMixerEntries() {
        mixer.update(notes: notes, selectedPrograms: selectedPrograms)
        engine.synthBank.apply(mixer: mixer)
    }

    // MARK: - Mixer

    func setGain(program: Int, db: Double) {
        mixer.setGain(program: program, db: db)
        engine.synthBank.apply(mixer: mixer)
    }

    func setMuted(program: Int, _ muted: Bool) {
        mixer.setMuted(program: program, muted: muted)
        engine.synthBank.apply(mixer: mixer)
    }

    func setSoloed(program: Int, _ soloed: Bool) {
        mixer.setSoloed(program: program, soloed: soloed)
        engine.synthBank.apply(mixer: mixer)
    }

    // MARK: - Models

    /// The preference; ``modelSize`` is what a run resolves it to.
    func setModelSize(_ size: ModelSize) {
        settings.modelSize = size
    }

    func startDownload(_ size: ModelSize) {
        downloader.start(size)
        refreshDownloadPhase(size)
    }

    func cancelDownload(_ size: ModelSize) {
        downloader.cancel(size)
    }

    /// Opens the models folder in the Finder, creating it first.
    func openModelsFolder() {
        try? paths.ensureDirectories()
        NSWorkspace.shared.open(paths.models)
    }

    private func refreshDownloadPhase(_ size: ModelSize) {
        let phase = downloader.phase(of: size)

        if downloadPhases[size] != phase {
            downloadPhases[size] = phase
        }

        // Idle after downloading means installed (or given up); either way the set may have moved.
        rescanInstalledModels()
    }

    /// 10 Hz, panel open or not (§3.2): the panel has to come back on its own when the last
    /// checkpoint disappears, and the toolbar's Transcribe button has to go with it.
    private func startModelPoll() {
        modelPollTimer?.invalidate()
        modelPollTimer = AppModel.repeatingTimer(hz: 10) { [weak self] in
            self?.rescanInstalledModels()
        }
    }

    private func rescanInstalledModels() {
        let installed = modelStore.installed()

        if installed != installedModels {
            installedModels = installed
        }
    }

    // MARK: - MIDI

    /// The file bytes, or nil unless the transcription is finished (§6.1).
    func midiData() -> Data? {
        guard canExport else { return nil }

        return MidiFileWriter.data(
            notes: notes, bpm: exportTempo, startOffsetSeconds: editor.grid.offsetSeconds, mode: settings.midiOverflowMode)
    }

    /// `<source>_NNTranscription.mid`, or `NNTranscription.mid` for a recorded take.
    func midiExportFileName() -> String {
        MidiFileWriter.exportFileName(sourceFileNameWithoutExtension: droppedFileName)
    }

    /// Writes the file into the drag scratch directory and hands back where, for the Drag button's
    /// item provider. Nil, with the §11.7 message shown, when it could not be written.
    func writeMidiForDrag() -> URL? {
        guard let data = midiData() else { return nil }

        do {
            try FileManager.default.createDirectory(at: paths.midiScratch, withIntermediateDirectories: true)
        } catch {
            showError("Error", "Temporary directory for midi file failed.")
            return nil
        }

        let url = paths.midiScratch.appendingPathComponent(midiExportFileName())

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError("Error", "Could not create the midi file.")
            return nil
        }

        return url
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
        panel.title = "Export MIDI"
        panel.message = "Export MIDI"
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = midiExportFileName()
        panel.allowedContentTypes = [.midi]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError("Error", "Could not write the MIDI file.")
        }
    }

    // MARK: - Update check

    /// Asks the releases endpoint whether a newer version exists and sets ``updateNotice`` (§9).
    /// `UpdateCheck` does the request off the main actor and lands the answer back here.
    ///
    /// - Parameter explicit: True from Check for Updates…, which is the only time
    ///   "You are on the latest version" is worth a notice.
    func checkForUpdates(explicit: Bool) {
        UpdateCheck.run(for: self, explicit: explicit)
    }

    func dismissUpdateNotice() {
        updateNotice = nil
    }

    // MARK: - Zoom

    /// View → Reset Zoom: horizontal back to 1, vertical back to automatic (§11.3).
    func resetZoom() {
        zoomLevel = 1
        verticalZoom = -1
    }

    // MARK: - Display link

    /// One frame: the transport mirrors, the live recording length, the meters and the notice's
    /// expiry. `dt` is the frame interval in seconds.
    func displayLinkTick(dt: Double) {
        syncTransport()

        if state == .recording {
            let seconds = recorder.durationSeconds

            if seconds != duration {
                duration = seconds
            }
        }

        advanceMeters(dt: dt)

        if let notice = updateNotice, Date() >= notice.expiresAt {
            updateNotice = nil
        }
    }

    // MARK: - Meters

    /// One instrument's level after ballistics, or the floor for a program not in the mix.
    func instrumentLevelDb(program: Int) -> Double {
        instrumentLevels[program] ?? MeterScale.minDb
    }

    /// Instant attack, 24 dB/s release, every meter fed the floor once the render thread has
    /// stood still for `max(0.5 s, 2 × block)` so a stopped engine's meters fall rather than
    /// stick (§2.5).
    private func advanceMeters(dt: Double) {
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
