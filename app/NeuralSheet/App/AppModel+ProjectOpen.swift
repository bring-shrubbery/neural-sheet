import AppKit
import Foundation
import NeuralSheetCore

/// Opening a project (projects design §4.2): the package is read and its audio decoded before the
/// current project is torn down, so a bad file costs nothing.
extension AppModel {
    // MARK: - Opening

    /// File → Open…: a panel titled "Open Project", the package type only.
    func openProjectFromPanel() {
        guard canChangeProject else { return }

        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Open Project"
        panel.allowedContentTypes = [.neuralSheetProject]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        openProject(url: url)
    }

    /// Opens the package at `url` in place of the current project. Read and decoded *before* the
    /// current project is touched, so a bad file costs nothing; a failure is one dialog.
    /// `reviewing: false` skips the save question (Revert's case).
    func openProject(url: URL, reviewing: Bool = true) {
        guard canChangeProject else { return }

        let package: ProjectPackage
        var audio: SourceAudio?

        let transcriptionUnreadable: Bool

        do {
            let read = try ProjectPackage.read(from: url)
            package = read.package
            transcriptionUnreadable = read.transcriptionUnreadable

            if let audioURL = read.audioURL {
                audio = try AudioFileLoader.load(url: audioURL,
                                                 deviceRate: engine.sampleRate,
                                                 namedAfterFile: package.state.audioDisplayName != nil)
            }
        } catch {
            showError("Could not open the project.", AppModel.describe(error))
            return
        }

        let install: () -> Void = { [weak self] in
            self?.installProject(package, audio: audio, url: url, transcriptionUnreadable: transcriptionUnreadable)
        }

        if reviewing {
            reviewProject(then: install)
        } else {
            install()
        }
    }

    /// Past the checks: the empty project first, then the settings, the audio, the notes (only
    /// against the very audio they were made from), the view state.
    ///
    /// - Parameter transcriptionUnreadable: True when `transcription.json` was there but did not
    ///   decode (``ProjectPackage/read(from:)``). Together with a sample-count mismatch this
    ///   decides ``notesDropped``: when true, the project is left edited rather than marked saved,
    ///   so the dot shows and the next Save (or Close's review) is the user's own choice rather
    ///   than a silent deletion of the notes from disk.
    private func installProject(_ package: ProjectPackage, audio: SourceAudio?, url: URL, transcriptionUnreadable: Bool) {
        replaceWithEmpty()

        let notesDropped: Bool

        if transcriptionUnreadable {
            notesDropped = true
        } else if let transcription = package.transcription {
            if let audio {
                notesDropped = audio.mono16k.count != transcription.sourceSampleCount
            } else {
                notesDropped = true
            }
        } else {
            notesDropped = false
        }

        let saved = package.state
        selectedGroups = AppModel.normalised(saved.selectedGroups.compactMap(InstrumentGroup.init(rawValue:)))

        // The mix is a whole: what the file has replaces what is there, program by program.
        for (program, channel) in saved.mixer {
            setGain(program: program, db: channel.gainDb)
            setMuted(program: program, channel.muted)
            setSoloed(program: program, channel.soloed)
        }

        exportTempo = saved.exportTempo
        editor.grid.offsetSeconds = max(0, saved.gridOffsetSeconds)
        editor.grid.division = saved.gridDivision
        editor.snapEnabled = saved.snapEnabled
        followPlayhead = saved.playheadCentered
        zoomLevel = saved.zoomLevel
        verticalZoom = saved.verticalZoom

        if let audio {
            installSource(audio)
        }

        if let audio, let transcription = package.transcription, audio.mono16k.count == transcription.sourceSampleCount {
            installDocument(rawNotes: transcription.rawNotes, document: transcription.document)
            transition(to: .populated)

            if let target = saved.targetProgram {
                setTargetProgram(target)
            }

            setWorkspace(saved.workspace)
        }

        if state.canPlay, saved.playheadSeconds > 0 {
            seek(toSeconds: saved.playheadSeconds)
        }

        projectURL = url
        noteRecentProject(url)

        if notesDropped {
            // The baseline from `replaceWithEmpty()` stands, so `isProjectEdited` reads true: the
            // dot shows, and Close (or the next Save) reviews rather than silently overwriting the
            // file with the notes gone.
            showError(
                "Could not load the project's transcription.",
                "The notes in the file do not match its audio, or could not be read, and were left out. Saving the project will remove them from the file.")
        } else {
            markProjectSaved(audioFileName: saved.audioFileName)
        }
    }
}
