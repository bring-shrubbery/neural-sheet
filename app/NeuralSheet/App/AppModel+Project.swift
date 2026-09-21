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
        source !== lastSavedSource || projectContent() != lastSavedContent
    }

    /// After a save or an open: what is there now is what the file has.
    func markProjectSaved(audioFileName: String) {
        lastSavedContent = projectContent()
        lastSavedSource = source
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

    /// File → New Project, and the welcome window's Create.
    func newProject() {
        guard canChangeProject else { return }

        replaceWithEmpty()
    }
}
