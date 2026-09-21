import AppKit
import Foundation
import NeuralSheetCore

/// The project's lifecycle (projects design §4): one project at a time, in the one model. New,
/// Open, Save, Save As, Revert and Close all go through here; the dirty rule (§4.1) compares the
/// content now with the content last saved.
extension AppModel {
    // MARK: - State

    /// The window title: the file's display name, or "Untitled".
    var projectTitle: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Save, Save As, New, Open, Revert and Close: not while recording or transcribing.
    var canChangeProject: Bool { state != .recording && state != .processing }

    var canSaveProject: Bool { canChangeProject }

    var canRevertProject: Bool { canChangeProject && projectURL != nil && isProjectEdited }

    // MARK: - Snapshots

    /// The transcription as it stands, or nil until one has finished.
    func transcriptionSnapshot() -> ProjectTranscription? {
        guard state == .populated, let document, let source else { return nil }

        return ProjectTranscription(sourceSampleCount: source.mono16k.count,
                                    rawNotes: transcription.rawNotes,
                                    document: document)
    }

    /// The content the dirty rule compares (§3.4).
    func projectContent() -> ProjectContent {
        ProjectContent(transcription: transcriptionSnapshot(),
                       selectedGroups: selectedGroups.map(\.rawValue),
                       mixer: mixer.settings,
                       exportTempo: exportTempo,
                       gridOffsetSeconds: editor.grid.offsetSeconds,
                       gridDivision: editor.grid.division,
                       snapEnabled: editor.snapEnabled,
                       targetProgram: editor.targetProgram)
    }

    /// Everything `project.json` holds, ready to be written.
    func projectState(audioFileName: String) -> ProjectState {
        var state = ProjectState()
        state.audioFileName = audioFileName
        state.audioDisplayName = droppedFileName
        state.selectedGroups = selectedGroups.map(\.rawValue)
        state.mixer = mixer.settings
        state.exportTempo = exportTempo
        state.gridOffsetSeconds = editor.grid.offsetSeconds
        state.gridDivision = editor.grid.division
        state.snapEnabled = editor.snapEnabled
        state.targetProgram = editor.targetProgram
        state.workspace = workspace
        state.playheadSeconds = playheadSeconds
        state.playheadCentered = followPlayhead
        state.zoomLevel = zoomLevel
        state.verticalZoom = verticalZoom

        return state
    }

    /// The truth now, for the commands; ``isProjectEdited`` follows it a moment later.
    func computeProjectEdited() -> Bool {
        sourceGeneration != lastSavedSourceGeneration || projectContent() != lastSavedContent
    }

    /// After a save or an open: what is there now is what the file has.
    func markProjectSaved(audioFileName: String) {
        lastSavedContent = projectContent()
        lastSavedSourceGeneration = sourceGeneration
        lastSavedAudioFileName = audioFileName

        if isProjectEdited {
            isProjectEdited = false
        }
    }

    // MARK: - Replacing

    /// The empty project: no audio, no notes, the selection automatic, the mix and the grid at
    /// their defaults, untitled and clean. Every way out of a project ends here.
    func replaceWithEmpty() {
        clearNow()
        resetMixerSettingsForLaunch()
        selectedGroups = []
        editor = EditorState()
        followPlayhead = true
        zoomLevel = 1
        verticalZoom = -1
        projectURL = nil
        markProjectSaved(audioFileName: "")
    }

    /// File → New Project, and the welcome window's Create: the current project is reviewed
    /// first (nothing to ask when it is clean, as from the welcome window).
    func newProject() {
        guard canChangeProject else { return }

        reviewProject { [weak self] in
            self?.replaceWithEmpty()
        }
    }

    // MARK: - Review

    /// Runs `proceed` at once when the project is clean, otherwise after the standard sheet:
    /// Save writes first (the save panel included, for an untitled project) and proceeds only
    /// when the write succeeded; Don't Save proceeds; Cancel runs `cancelled`.
    func reviewProject(then proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard computeProjectEdited(), let presentSaveReview else {
            proceed()
            return
        }

        presentSaveReview(projectTitle) { [weak self] choice in
            guard let self else { return }

            switch choice {
            case .save:
                if saveProject() {
                    proceed()
                } else {
                    cancelled?()
                }
            case .discard:
                proceed()
            case .cancel:
                cancelled?()
            }
        }
    }

    // MARK: - Saving

    /// File → Save: the save panel for an untitled project, the file itself otherwise. True when
    /// the file was written.
    @discardableResult
    func saveProject() -> Bool {
        guard canSaveProject else { return false }
        guard let projectURL else { return saveProjectAs() }

        return writeProject(to: projectURL)
    }

    /// File → Save As…: a save panel titled "Save Project" beside the current file, or in the
    /// Music folder for an untitled one, named after the project or its audio.
    @discardableResult
    func saveProjectAs() -> Bool {
        guard canSaveProject else { return false }

        let panel = NSSavePanel()
        // `message` is what the modern panel shows; `title` is kept for the accessibility name.
        panel.title = "Save Project"
        panel.message = "Save Project"
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? paths.musicFolder
        panel.nameFieldStringValue = projectURL != nil ? projectTitle : (droppedFileName ?? "Untitled")
        panel.allowedContentTypes = [.neuralSheetProject]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        return writeProject(to: url)
    }

    /// The write itself. The audio comes from the package's own copy when it has not changed
    /// since the last save (an APFS clone, so an edit costs the JSON only), else from where the
    /// take was loaded or recorded.
    private func writeProject(to url: URL) -> Bool {
        var audioFileName = ""
        var audioSource: URL?

        if let source {
            audioFileName = source.droppedFileName == nil
                ? ProjectPackage.recordingFileName
                : (source.sourcePath?.lastPathComponent ?? ProjectPackage.recordingFileName)

            if sourceGeneration == lastSavedSourceGeneration, let projectURL, !lastSavedAudioFileName.isEmpty {
                audioFileName = lastSavedAudioFileName
                audioSource = ProjectPackage.audioURL(in: projectURL, fileName: audioFileName)
            } else if let path = source.sourcePath {
                audioSource = path
            } else {
                showError("Could not save the project.", "The audio has no file to copy.")
                return false
            }
        }

        let package = ProjectPackage(state: projectState(audioFileName: audioFileName),
                                     transcription: transcriptionSnapshot())

        do {
            try package.write(to: url, audioSource: audioSource)
        } catch {
            showError("Could not save the project.", AppModel.describe(error))
            return false
        }

        projectURL = url
        markProjectSaved(audioFileName: audioFileName)
        noteRecentProject(url)

        return true
    }

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

        do {
            let read = try ProjectPackage.read(from: url)
            package = read.package

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
            self?.installProject(package, audio: audio, url: url)
        }

        if reviewing {
            reviewProject(then: install)
        } else {
            install()
        }
    }

    /// Past the checks: the empty project first, then the settings, the audio, the notes (only
    /// against the very audio they were made from), the view state.
    private func installProject(_ package: ProjectPackage, audio: SourceAudio?, url: URL) {
        replaceWithEmpty()

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
        markProjectSaved(audioFileName: saved.audioFileName)
        noteRecentProject(url)
    }

    // MARK: - Revert and close

    /// File → Revert to Saved…: the standard question, then the file again without the review.
    func revertProject() {
        guard canRevertProject, let url = projectURL, let presentRevert else { return }

        presentRevert(projectTitle) { [weak self] confirmed in
            guard confirmed else { return }

            self?.openProject(url: url, reviewing: false)
        }
    }

    /// The window's close: the review, then the empty project, then `proceed` (the window goes
    /// and the welcome window comes).
    func closeProject(then proceed: @escaping () -> Void) {
        guard canChangeProject else { return }

        reviewProject { [weak self] in
            self?.replaceWithEmpty()
            proceed()
        }
    }

    // MARK: - Recents

    /// The system's recent-documents list (the Dock menu reads it too). Filled in Task 7.
    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: - Errors

    /// The dialog's body for a project error: the spec §7 wording per case, the system's
    /// description otherwise.
    static func describe(_ error: Error) -> String {
        if error is AudioFileLoader.LoadError {
            return "The project's audio file could not be decoded."
        }

        guard let error = error as? ProjectError else {
            return error.localizedDescription
        }

        switch error {
        case .notAPackage:
            return "The file is not a NeuralSheet project."
        case let .unreadable(reason):
            return "The project file could not be read: \(reason)"
        case .newerVersion:
            return "The project was saved by a newer version of NeuralSheet."
        case .missingAudio:
            return "The project's audio file is missing."
        case let .couldNotWrite(reason):
            return reason
        }
    }
}
