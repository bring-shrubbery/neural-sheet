import Foundation
import NeuralSheetCore

/// Loading a take -- a dropped or chosen file, or one the pipeline hands over -- and the clears
/// that drop the take, the transcription or both, with the recorded files they leave behind.
extension AppModel {
    /// Loads a dropped or chosen file, replacing whatever was there (§2.2). Not while recording
    /// or transcribing. Edited notes are asked about first, as any clear does (design §3.5), and
    /// the load waits on the answer.
    func loadAudio(url: URL) {
        guard state == .empty || state == .audioLoaded || state == .populated, regionJob == nil, importJob == nil
        else { return }

        // Before anything is cleared: the C++ drop target refuses an unknown extension ahead of
        // `onFileDrop`, so a stray .txt on a finished transcription costs nothing.
        guard AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            showError(String(localized: "Could not load the file.", comment: "Alert title: a dropped or opened file could not be read"),
                      AppModel.checkFormatMessage)
            return
        }

        confirmDiscardingEdits(String(localized: "The transcription has been edited. Loading another file will throw the edits away.",
                                      comment: "Alert body: loading a file over an edited transcription")) { [weak self] in
            guard let self else { return }

            clearNow()
            load(url: url)
        }
    }

    /// A video goes off the main actor to have its audio extracted (`AppModel+Import.swift`);
    /// anything else is decoded here, synchronously, as it always was.
    private func load(url: URL) {
        if AudioFileLoader.isVideo(url) {
            importVideo(url: url)
            return
        }

        let audio: SourceAudio

        do {
            audio = try AudioFileLoader.load(url: url, deviceRate: engine.sampleRate)
        } catch {
            presentLoadFailure()
            return
        }

        installSource(audio)
    }

    /// Every failure after the clear, the video path's included. The list is the loader's own
    /// (input formats design §2); NeuralNote's message hard-coded the five formats it had.
    func presentLoadFailure() {
        showError(String(localized: "Could not load the audio file.", comment: "Alert title: an audio file could not be decoded"),
                  AppModel.checkFormatMessage)
    }

    /// Hands a take to the engine and moves to `audioLoaded`. The pipeline's and the project's
    /// (`AppModel+Project.swift`), never a view's.
    func installSource(_ audio: SourceAudio) {
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
        guard !jobActive, regionJob == nil, importJob == nil else { return }

        confirmDiscardingEdits(String(localized: "The transcription has been edited. Clearing will throw the edits away.",
                                      comment: "Alert body: clearing an edited transcription")) { [weak self] in
            self?.clearNow()
        }
    }

    /// `clear()` past the question: the pipeline's, for a take too short to run and for a
    /// recording that failed -- neither has edits to ask about.
    func clearNow() {
        let wasRecording = state == .recording || state == .countingIn

        if wasRecording {
            // The take is discarded whatever came of it -- a count-in cancelled after its
            // downbeat may already hold a few blocks; the files go below.
            _ = recorder.stop()
        }

        // A video's extraction in flight is abandoned: the cancelled task installs nothing,
        // shows nothing and removes its own file (`AppModel+Import.swift`).
        importJob?.cancel()
        importJob = nil

        // Export Stems…'s separation belongs to the take going away.
        cancelStemsExport()

        resetTranscription()
        engine.setSource(nil)
        deleteRecordedFiles()

        // Versions are of this take's notes (versions design §2); a clear of the notes alone
        // keeps them for the run that follows.
        versions = []
        notesBeforeRun = nil
        isManageVersionsPresented = false

        source = nil
        duration = 0
        transition(to: .empty)

        if wasRecording {
            endRecordingClick()
        }
    }

    /// The transcription only, keeping the audio (§2.6).
    func clearTranscription() {
        guard !jobActive, regionJob == nil else { return }

        confirmDiscardingEdits(String(localized: "The transcription has been edited. Clearing will throw the edits away.",
                                      comment: "Alert body: clearing an edited transcription")) { [weak self] in
            // The clear is how a take is transcribed again: the next run saves these as
            // "Before Transcribe" (versions design §2).
            self?.keepNotesForNextRun()
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

        // A region run in flight is abandoned: its completion finds no job and does nothing.
        // `transcriber.isRunning` stays true until the engine reaches the next chunk boundary,
        // and the main run's launch refuses until then, as it does after a cancel today.
        if regionJob != nil {
            regionJob = nil
            transcriber.cancel()
        }

        abandonStemsRun()
        // Track Pitch in flight lands nothing: its task finds itself cancelled when it hops back.
        pitchJob?.cancel()
        pitchJob = nil
        transcription = TranscriptionState()
        staging.reset()
        document = nil
        comparedVersion = nil
        comparisonSummary = nil
        editor.selection = []
        editor.range = nil
        highlightedProgram = nil
        _ = dragCanceller?()

        // Otherwise the synth keeps playing the notes of the transcription just thrown away.
        engine.synthBank.scheduler.swap(notes: [])
        engine.synthBank.reset()
        engine.refreshGains()

        refreshMixerEntries()
        instrumentLevels = [:]
        meterLevels.resetInstruments()

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

        if let importedAudioURL {
            removeImportFolder(importedAudioURL.deletingLastPathComponent())
            self.importedAudioURL = nil
        }

        // The take's kept stems (audio export design §2).
        if let stemsFolder {
            removeImportFolder(stemsFolder)
            self.stemsFolder = nil
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
}
