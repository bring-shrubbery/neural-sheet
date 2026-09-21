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

    /// New, Open, Revert and Close: not while recording or transcribing.
    var canChangeProject: Bool { state != .recording && state != .processing }

    /// Save and Save As: not while recording (there is no take yet). A save during a
    /// transcription writes the audio and the settings without the notes, which is what the quit
    /// review needs.
    var canSaveProject: Bool { state != .recording }

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
    /// when the write succeeded; Don't Save proceeds; Cancel runs `cancelled`. A missing
    /// `presentSaveReview` with nothing to lose proceeds silently, as before there is a window;
    /// a missing `presentSaveReview` with unsaved changes is a wiring bug (`showError`'s own
    /// convention), so a debug build says so and then proceeds rather than losing the work
    /// silently.
    func reviewProject(then proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard computeProjectEdited() else {
            proceed()
            return
        }

        guard let presentSaveReview else {
            assertionFailure("presentSaveReview is not installed; unsaved changes would be dropped")
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

    /// The write itself. The audio comes from ``audioSourceForWrite()``; a project without audio
    /// writes none.
    private func writeProject(to url: URL) -> Bool {
        var audioFileName = ""
        var audioSource: URL?

        if source != nil {
            guard let audio = audioSourceForWrite() else { return false }

            audioFileName = audio.fileName
            audioSource = audio.url
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

    /// Where the next save copies the audio from, and what it is called inside the package.
    ///
    /// The package's own copy when the take has not changed since the last save (an APFS clone, so
    /// an edit costs the JSON only), else where the take was loaded or recorded. The package's
    /// copy is checked to still be there: a package moved, renamed or deleted in the Finder while
    /// it is open is not followed, and without the check every save after that would fail for good.
    /// The take's original path is the fallback, and a save with neither says so rather than
    /// writing a package with no audio in it.
    private func audioSourceForWrite() -> (fileName: String, url: URL)? {
        guard let source else { return nil }

        let manager = FileManager.default

        if sourceGeneration == lastSavedSourceGeneration, let projectURL, !lastSavedAudioFileName.isEmpty {
            let saved = ProjectPackage.audioURL(in: projectURL, fileName: lastSavedAudioFileName)

            if manager.fileExists(atPath: saved.path) {
                return (lastSavedAudioFileName, saved)
            }
        }

        let fileName = source.droppedFileName == nil
            ? ProjectPackage.recordingFileName
            : (source.sourcePath?.lastPathComponent ?? ProjectPackage.recordingFileName)

        guard let path = source.sourcePath else {
            showError("Could not save the project.", "The audio has no file to copy.")
            return nil
        }

        guard manager.fileExists(atPath: path.path) else {
            showError("Could not save the project.",
                      "The project's audio file is no longer where it was saved.")
            return nil
        }

        return (fileName, path)
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

    /// The window's close button and ⌘W: refused with a beep while recording or transcribing;
    /// otherwise the review runs, and the window is closed for real once the project is cleared
    /// and the welcome window is up. Always false: `NSWindow.close()` does not ask again, so the
    /// window goes exactly once.
    func handleWindowClose(_ window: NSWindow) -> Bool {
        guard canChangeProject else {
            NSSound.beep()
            return false
        }

        closeProject { [weak self] in
            self?.showWelcomeWindow?()
            AppModel.closeWhenAnotherWindowIsUp(window, attempts: 10)
        }

        return false
    }

    /// Closes `window` once some other window is on screen, trying again on the next few main-queue
    /// turns if none is yet.
    ///
    /// The welcome window is asked for first, but SwiftUI opens it when it gets round to it, and
    /// the app quits with its last window: closing the project window while it is still the only
    /// one would quit instead of showing the welcome window. AppKit promises nothing about the
    /// order, so this waits rather than assuming one turn is enough -- and gives up after
    /// `attempts` turns, so a welcome window that never comes leaves the close done rather than a
    /// window that cannot be shut.
    private static func closeWhenAnotherWindowIsUp(_ window: NSWindow, attempts: Int) {
        DispatchQueue.main.async {
            let another = NSApp.windows.contains { $0 !== window && $0.isVisible }

            if another || attempts <= 1 {
                window.close()
            } else {
                closeWhenAnotherWindowIsUp(window, attempts: attempts - 1)
            }
        }
    }

    // MARK: - Recents

    /// The system's recent-documents list (the Dock menu reads it too); a project the user had
    /// removed from the welcome window's list comes back when it is opened or saved again.
    func noteRecentProject(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        settings.hiddenRecentProjects.removeAll { $0 == url.path }
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
        case .notFound:
            return "The project file could not be found."
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
