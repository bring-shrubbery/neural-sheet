import AppKit
import Foundation
import NeuralSheetCore
import Observation

/// What the app remembers (inventory §8): the session -- the take's path, the transport, the zoom,
/// the selection and the mix -- the finished transcription in a file of its own beside it, and the
/// global settings.
extension AppModel {
    // MARK: - Session

    /// The session as it stands, ready to be written.
    ///
    /// The MIDI overflow mode lives in the global settings here (that is what the writer reads);
    /// the session carries a copy so the file says what the export would do, as the original's did.
    func sessionSnapshot() -> SessionState {
        var session = SessionState()
        session.exportTempo = exportTempo
        session.midiOverflowMode = settings.midiOverflowMode
        session.sourceAudioPath = source?.sourcePath?.path ?? ""
        session.playheadSeconds = playheadSeconds
        session.playheadCentered = followPlayhead
        session.zoomLevel = zoomLevel
        session.verticalZoom = verticalZoom
        session.selectedGroups = selectedGroups.map(\.rawValue)
        session.mixer = mixer.settings
        session.workspace = workspace
        session.gridOffsetSeconds = editor.grid.offsetSeconds
        session.gridDivision = editor.grid.division
        session.snapEnabled = editor.snapEnabled
        session.targetProgram = editor.targetProgram

        return session
    }

    /// The transcription as it stands, or nil until one has finished. Not part of the session
    /// snapshot: it is megabytes for a long take, and the session is rewritten as the playhead
    /// moves.
    func transcriptionSnapshot() -> SessionTranscription? {
        guard state == .populated, let document, let source else { return nil }

        return SessionTranscription(sourceSampleCount: source.mono16k.count,
                                    rawNotes: transcription.rawNotes,
                                    document: document)
    }

    /// Writes the session now, and the transcription beside it. A failure is not worth a dialog:
    /// the session is a convenience, and the next save will try again.
    func saveSession() {
        saveSessionState()
        saveTranscription()
    }

    /// The session file alone: the small one, written as the playhead moves.
    func saveSessionState() {
        try? paths.ensureDirectories()
        try? sessionSnapshot().save(to: paths.session)
    }

    /// The transcription file alone, or its removal when there is no finished transcription, so a
    /// stale one is never restored against a later take.
    func saveTranscription() {
        try? paths.ensureDirectories()

        if let snapshot = transcriptionSnapshot() {
            try? snapshot.save(to: paths.transcription)
        } else {
            try? FileManager.default.removeItem(at: paths.transcription)
        }
    }

    /// Restores the session at `paths.session` (§8.2): the audio is re-read from its path when
    /// the file still exists, then the playhead, the zoom, the selection, the mix and the
    /// transcription are put back.
    ///
    /// Only into an empty model, and only once the view has installed `presentError`: re-reading
    /// a file that has gone bad shows the same dialog a drop of it would.
    func restoreSession() {
        guard state == .empty else { return }

        let session = SessionState.load(from: paths.session)

        exportTempo = session.exportTempo
        followPlayhead = session.playheadCentered
        zoomLevel = session.zoomLevel
        verticalZoom = session.verticalZoom

        let groups = session.selectedGroups.compactMap(InstrumentGroup.init(rawValue:))
        selectedGroups = AppModel.normalised(groups)

        // The mix is a whole: what the file has replaces what is there, program by program.
        for (program, channel) in session.mixer {
            setGain(program: program, db: channel.gainDb)
            setMuted(program: program, channel.muted)
            setSoloed(program: program, channel.soloed)
        }

        editor.grid.offsetSeconds = max(0, session.gridOffsetSeconds)
        editor.grid.division = session.gridDivision
        editor.snapEnabled = session.snapEnabled

        if !session.sourceAudioPath.isEmpty {
            restoreAudio(url: URL(fileURLWithPath: session.sourceAudioPath))
        }

        // The notes only with the very audio they were made from. A session written before the
        // transcription had its own file still carries it.
        let saved = SessionTranscription.load(from: paths.transcription) ?? session.transcription

        if state == .audioLoaded, let saved, let source, source.mono16k.count == saved.sourceSampleCount {
            installDocument(rawNotes: saved.rawNotes, document: saved.document)
            transition(to: .populated)

            if let target = session.targetProgram {
                setTargetProgram(target)
            }

            setWorkspace(session.workspace)
        }

        if state.canPlay, session.playheadSeconds > 0 {
            seek(toSeconds: session.playheadSeconds)
        }
    }

    // MARK: - Global settings

    /// Writes every key (§8.1), so the file always lists what the app is using.
    func saveGlobalSettings() {
        try? paths.ensureDirectories()
        try? settings.save(to: paths.globalSettings)
    }

    // MARK: - Teardown

    /// What the drag button left in the temp directory goes with the app (§8.3).
    func deleteMidiScratch() {
        try? FileManager.default.removeItem(at: paths.midiScratch)
    }
}

/// Keeps the files on disk in step with the model: the global settings on every change, the
/// session and the transcription 500 ms after the last change to any of their fields -- each file
/// only when its own contents changed -- and again as the app terminates, when the MIDI drag
/// scratch is removed too. One per app, created beside the model.
@MainActor final class Persistence {
    private let model: AppModel
    private var sessionSaveTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    private var lastSavedSession: SessionState?
    private var lastSavedTranscription: SessionTranscription?
    private var hasRestored = false

    /// Between the last change and the write.
    static let sessionDebounce: TimeInterval = 0.5

    init(model: AppModel) {
        self.model = model
    }

    /// Restores the session the first time the window appears, and never again: a window closed
    /// and reopened keeps what it had.
    func restoreOnce() {
        guard !hasRestored else { return }

        hasRestored = true
        model.restoreSession()
    }

    /// Starts watching. Call once, after the session has been restored, so the restore itself is
    /// not what triggers the first save.
    func start() {
        guard terminateObserver == nil else { return }

        Tooltips.enabled = model.settings.tooltipsVisible
        lastSavedSession = model.sessionSnapshot()
        lastSavedTranscription = model.transcriptionSnapshot()

        observeSettings()
        observeSession()

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminate()
            }
        }
    }

    /// The last write, and the scratch directory with it.
    private func terminate() {
        sessionSaveTimer?.invalidate()
        sessionSaveTimer = nil
        model.saveSession()
        // Whatever the observer above has not caught up with yet: the settings write is
        // asynchronous, and the app is about to stop running the loop it is queued on.
        model.saveGlobalSettings()
        model.deleteMidiScratch()
    }

    // MARK: - Settings

    /// Every setter of `NnGlobalSettings` rewrote the file; here the file follows the struct.
    private func observeSettings() {
        withObservationTracking {
            _ = model.settings
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                Tooltips.enabled = self.model.settings.tooltipsVisible
                self.model.saveGlobalSettings()
                self.observeSettings()
            }
        }
    }

    // MARK: - Session

    /// Reads every field the two snapshots are made of, so the next write to any of them -- an
    /// edit included -- schedules a save. The playhead moves every frame during playback: a save
    /// already pending absorbs those writes, and the timer is re-armed only once it has fired -- so
    /// a session that keeps changing is written at most twice a second, not once 500 ms after it
    /// finally stops.
    private func observeSession() {
        withObservationTracking {
            _ = model.sessionSnapshot()
            _ = model.transcriptionSnapshot()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }

                self.scheduleSessionSave()
                self.observeSession()
            }
        }
    }

    private func scheduleSessionSave() {
        guard sessionSaveTimer == nil else { return }

        let timer = Timer(timeInterval: Self.sessionDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionSaveTimer = nil
                self?.saveSessionIfChanged()
            }
        }

        // `.common`, so a change made from a menu or during a drag is still written.
        RunLoop.main.add(timer, forMode: .common)
        sessionSaveTimer = timer
    }

    /// A playhead that stopped where it was, or a mix set back to what it was, costs no write; and
    /// a playhead that moved never rewrites the transcription, which is written only when a note
    /// changed.
    private func saveSessionIfChanged() {
        let session = model.sessionSnapshot()

        if session != lastSavedSession {
            lastSavedSession = session
            model.saveSessionState()
        }

        let transcription = model.transcriptionSnapshot()

        if transcription != lastSavedTranscription {
            lastSavedTranscription = transcription
            model.saveTranscription()
        }
    }
}
