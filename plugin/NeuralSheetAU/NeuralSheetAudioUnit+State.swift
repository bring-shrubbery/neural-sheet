import AudioToolbox
import Foundation
import NeuralSheetCore
import Synchronization
import os

/// What the unit gives the host to save: the session as the view model last pushed it (the take
/// left out), the take, and the take's ALAC once encoded. The unit's ``NeuralSheetAudioUnit/savedState``.
nonisolated struct SavedStateStore {
    /// Everything but the take, kept current by the view model.
    var session = PluginState()
    var take: CapturedTake?
    /// ``take`` as ALAC, encoded in the background when the take changes; nil until then.
    var encodedTake: PluginState.Take?
    /// The blob a restore is decoding, handed back as it is while it does, so a host that saves
    /// straight after loading saves what it loaded.
    var restoring: Data?
    /// Bumped by every restore, so only the last one lands.
    var restoreGeneration = 0
}

/// A host's saved state, decoded: the settings and notes, and the take rebuilt from its ALAC.
nonisolated struct RestoredSession: Sendable {
    var state: PluginState
    var take: CapturedTake?
}

/// Where a restore lands on the main thread: the view model's handler once it has connected, or
/// kept until it does (a host restores right after making the unit, before the view model has
/// it). Main thread only.
nonisolated final class RestoreInbox: @unchecked Sendable {
    var pending: RestoredSession?
    var deliver: ((RestoredSession) -> Void)?
}

/// The host's saved state (Audio Unit design §2, "State"): `fullState` carries a ``PluginState``
/// under a key of its own beside the superclass's keys (``PluginFullState``). The parameters --
/// there are none -- and `allParameterValues` are the superclass's.
///
/// A host may ask for or hand over the state on any thread, so nothing here waits for the main
/// thread: the getter codes what the view model last pushed, and the setter decodes on a queue of
/// its own and lands on the main thread when done.
extension NeuralSheetAudioUnit {
    override var fullState: [String: Any]? {
        get { PluginFullState.merging(savedStateBlob(), into: super.fullState) }
        set {
            super.fullState = newValue
            restoreState(from: PluginFullState.blob(in: newValue))
        }
    }

    // MARK: - Saving

    /// The state's bytes now: the blob being restored while a restore runs, else the session with
    /// the take, encoding it here if the background has not yet.
    nonisolated func savedStateBlob() -> Data? {
        let saved = savedState.withLock { $0 }

        if let restoring = saved.restoring { return restoring }

        var state = saved.session

        if let take = saved.take {
            let encoded = saved.encodedTake ?? PluginState.Take.make(from: take)
            state.take = encoded

            if saved.encodedTake == nil, let encoded {
                savedState.withLock { store in
                    if store.take?.source === take.source { store.encodedTake = encoded }
                }
            }
        }

        return state.encode()
    }

    /// The session from now on, without the take. Main actor, from the view model.
    @MainActor
    func setSavedSession(_ session: PluginState) {
        var session = session
        session.take = nil
        savedState.withLock { $0.session = session }
    }

    /// The take from now on, encoded to ALAC in the background so a save does not wait for it.
    /// The same take again changes nothing. Main actor, from the view model.
    @MainActor
    func setSavedTake(_ take: CapturedTake?) {
        let changed = savedState.withLock { store -> Bool in
            guard store.take?.source !== take?.source else { return false }

            store.take = take
            store.encodedTake = nil
            return true
        }

        guard changed, let take else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let encoded = PluginState.Take.make(from: take) else { return }

            self?.savedState.withLock { store in
                if store.take?.source === take.source, store.encodedTake == nil { store.encodedTake = encoded }
            }
        }
    }

    // MARK: - Restoring

    /// Decodes `blob` off the calling thread, rebuilds the take, and lands on the main thread.
    /// No blob (a preset the host made from parameters alone) leaves the session as it is.
    nonisolated func restoreState(from blob: Data?) {
        guard let blob else { return }

        let generation = savedState.withLock { store -> Int in
            store.restoreGeneration += 1
            store.restoring = blob
            return store.restoreGeneration
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = PluginState.decode(blob)
            let take = state?.take?.restore()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishRestore(generation: generation, state: state, take: take)
                }
            }
        }
    }

    /// The decoded state becomes what the unit saves and is handed to the view model. A state
    /// that did not decode is dropped and the session stays as it was.
    @MainActor
    private func finishRestore(generation: Int, state: PluginState?, take: CapturedTake?) {
        let current = savedState.withLock { store -> Bool in
            guard store.restoreGeneration == generation else { return false }

            store.restoring = nil

            if let state {
                var session = state
                session.take = nil
                store.session = session
                store.take = take
                store.encodedTake = take != nil ? state.take : nil
            }
            return true
        }

        guard current else { return }

        guard let state else {
            PluginLog.logger.error("state: not restored (another version, or damaged)")
            return
        }

        if state.take != nil, take == nil {
            PluginLog.logger.error("state: the take's audio did not decode")
        }
        PluginLog.logger.info(
            "state: restored, take \(take.map { String(format: "%.2f s", $0.duration) } ?? "none", privacy: .public), \(state.transcription?.document.notes.count ?? 0) notes")

        let restored = RestoredSession(state: state, take: take)

        if let deliver = restoreInbox.deliver {
            deliver(restored)
        } else {
            restoreInbox.pending = restored
        }
    }

    /// The view model's handler for restores from now on; one that landed before it is handed
    /// over at once.
    @MainActor
    func onRestore(_ deliver: @escaping (RestoredSession) -> Void) {
        restoreInbox.deliver = deliver

        if let pending = restoreInbox.pending {
            restoreInbox.pending = nil
            deliver(pending)
        }
    }
}
