import Foundation
import NeuralSheetCore

/// What a save writes, field for field as the Mac's `AppModel+Project.swift`: the state
/// `project.json` holds and the transcription beside it.
extension MobileModel {
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
}
