import AppKit
import Foundation
import NeuralSheetCore
import Observation
import os

/// What the view shows and the commands it sends the unit. Main actor.
@Observable final class PluginViewModel {
    /// The output's sample rate, nil until the host has made the unit.
    var sampleRate: Double?

    /// Record / Arm / Stop and the take, nil until the host has made the unit.
    private(set) var capture: CaptureSession?

    /// The checkpoints in the App Group container, read again when the view appears and on
    /// Check Again (the user may have downloaded one in the app meanwhile).
    private(set) var models: PluginModels

    /// Set when Open NeuralSheet found no app to open.
    private(set) var appMissing = false

    /// The run over the take and the notes it found (sub-issue C).
    let transcription = PluginTranscription()

    /// The synth, the mix, the strips and the transport (sub-issue D).
    let playback = PluginPlayback()

    /// The model picked in the view; nil follows the app's setting.
    var pickedSize: ModelSize?

    /// The instruments the decoder is held to; empty is Automatic.
    var selectedGroups: [InstrumentGroup] = []

    /// Separate the take into stems first, when the Demucs weights are installed. Starts as the
    /// app's Transcribe toolbar left it.
    var separateStems: Bool

    /// The app's settings, shared through the group: the model size, the Stems toggle and the
    /// After transcription filter. Read again at every run.
    @ObservationIgnored private var settings: GlobalSettings

    /// The paths inside the extension's sandbox: the models and the settings in the group
    /// container (Audio Unit design §2, "Models and settings").
    @ObservationIgnored let paths: AppPaths

    @ObservationIgnored private weak var unit: NeuralSheetAudioUnit?

    let version: String = {
        let info = Bundle(for: NeuralSheetAUViewController.self).infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? ""
    }()

    /// The Mac app, opened by its bundle identifier wherever it is installed.
    static let appBundleIdentifier = "com.quassum.neuralsheet"

    init(paths: AppPaths = .standard) {
        self.paths = paths
        models = PluginModels(store: ModelStore(paths: paths))
        settings = GlobalSettings.load(from: paths.globalSettings)
        separateStems = settings.separateStems

        let installed = models.transcription.map(\.rawValue) + (models.stemsInstalled ? ["stems"] : [])
        PluginLog.logger.info("models in \(paths.models.path, privacy: .public): \(installed, privacy: .public)")
    }

    func connect(_ unit: NeuralSheetAudioUnit) {
        self.unit = unit
        capture = unit.capture
        playback.connect(unit)

        // The take and the notes reach the playback as they change, view or no view.
        let playback = playback
        unit.capture.onTakeChanged = { take in playback.setTake(take) }
        transcription.onNotesChanged = { notes in playback.setNotes(notes) }
        playback.setTake(unit.capture.take)
        playback.setNotes(transcription.notes)
    }

    // MARK: - Capture

    /// A new take replaces the notes of the last.
    func record() {
        guard !transcription.isRunning else { return }

        transcription.clear()
        unit?.startCapture()
    }

    func arm() {
        guard !transcription.isRunning else { return }

        transcription.clear()
        unit?.arm()
    }

    func stop() {
        unit?.stopCapture()
    }

    func clear() {
        transcription.clear()
        capture?.clear()
    }

    // MARK: - Transcription

    /// The size Transcribe runs with.
    var size: ModelSize? { models.size(picked: pickedSize, preferred: settings.modelSize) }

    /// Whether Stems is offered and on.
    var stemsChosen: Bool { separateStems && models.stemsInstalled }

    /// A take of a second or more, a model, and nothing else under way.
    var canTranscribe: Bool {
        guard !transcription.isRunning, size != nil, let capture, capture.phase == .idle,
              let take = capture.capturedTake
        else { return false }

        return take.mono16k.count >= TranscriptionPlan.minimumSamples
    }

    func transcribe() {
        refreshModels()
        settings = GlobalSettings.load(from: paths.globalSettings)

        let store = ModelStore(paths: paths)

        guard canTranscribe, let take = capture?.capturedTake, let size, let modelPath = store.installedPath(for: size)
        else { return }

        transcription.start(source: take, modelPath: modelPath,
                            stemsPath: stemsChosen ? store.installedPath(for: .stems) : nil,
                            groups: selectedGroups, settings: settings)
    }

    /// What the roll draws: the take, and the stream or the landed notes.
    var rollContent: PluginRollContent? {
        guard let take = capture?.capturedTake else { return nil }

        return PluginRollContent(duration: take.duration, peaks: take.peaks, notes: transcription.notes,
                                 frontier: transcription.run?.finalizedThrough,
                                 muted: Set(playback.mixer.entries.map(\.program).filter { !playback.mixer.isAudible(program: $0) }))
    }

    func cancelTranscription() {
        transcription.cancel()
    }

    /// Automatic, or one instrument more or less.
    func toggle(_ group: InstrumentGroup?) {
        guard let group else {
            selectedGroups = []
            return
        }

        if let index = selectedGroups.firstIndex(of: group) {
            selectedGroups.remove(at: index)
        } else {
            selectedGroups.append(group)
            selectedGroups.sort { $0.rawValue < $1.rawValue }
        }
    }

    // MARK: - Models

    func refreshModels() {
        let scanned = PluginModels(store: ModelStore(paths: paths))

        if scanned != models {
            models = scanned
        }
    }

    /// Open NeuralSheet, where the models are downloaded (Settings › Model).
    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) else {
            appMissing = true
            return
        }

        appMissing = false
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
