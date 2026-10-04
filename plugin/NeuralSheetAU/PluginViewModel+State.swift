import Foundation
import NeuralSheetCore
import Observation

/// The session the host saves with its project (Audio Unit design §2, "State"): kept current on
/// the unit as it changes, so a save on the host's thread never waits for the main thread, and put
/// back when the host restores it. Main actor.
extension PluginViewModel {
    /// Everything the host saves but the take, which the unit has as it is.
    func savedSession() -> PluginState {
        var state = PluginState()

        if let document = transcription.document, let take = capture?.take {
            state.transcription = ProjectTranscription(sourceSampleCount: take.source.mono16k.count,
                                                       rawNotes: document.events, document: document)
        }

        state.modelSize = pickedSize
        state.selectedGroups = selectedGroups.map(\.rawValue)
        state.separateStems = separateStems
        state.mix = playback.mix
        state.masterGainDb = playback.masterGainDb
        state.mixer = playback.mixer.settings
        state.sendsMIDI = playback.sendsMIDI
        return state
    }

    /// Pushes ``savedSession()`` to the unit now and again whenever what it reads changes.
    func trackSavedSession() {
        let session = withObservationTracking {
            savedSession()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.trackSavedSession()
            }
        }

        unit?.setSavedSession(session)
    }

    /// A host's saved state, in place of the session: the strips before the notes, so they keep
    /// their settings, then the notes, then the take.
    func apply(_ restored: RestoredSession) {
        let state = restored.state

        playback.restore(mix: state.mix, masterGainDb: state.masterGainDb, mixer: state.mixer,
                         sendsMIDI: state.sendsMIDI)
        pickedSize = state.modelSize
        selectedGroups = InstrumentGroup.allCases.filter { state.selectedGroups.contains($0.rawValue) }
        separateStems = state.separateStems
        transcription.restore(restored.take != nil ? state.transcription?.document : nil)
        capture?.restore(restored.take)
        takeWasCut = state.take?.truncated ?? false
        handoff = .idle
    }
}
