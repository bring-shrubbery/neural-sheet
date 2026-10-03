import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization

/// The gains: the crossfade, the master fader, mute and the stereo split, resolved through
/// ``MixLaw`` and handed to the render state, the synth bank and the mixers. Main thread.
nonisolated extension PlaybackEngine {
    /// Re-applies the gains from outside. The mix depends on whether the scheduler has any notes
    /// (§5.3), which changes when a decoded chunk arrives rather than when a control moves.
    func refreshGains() {
        updateGains()
    }

    /// The gains through ``MixLaw``, the one formula the offline renderer shares (audio export
    /// design §2).
    // Internal: the mix settings' didSets, the init and rebuildGraph call it.
    func updateGains() {
        let gains = MixLaw.resolve(mix: mix, masterGainDb: masterGainDb, muted: muted, stereoSplit: stereoSplit,
                                   hasNotes: synthBank.scheduler.hasNotes)

        state.sourceGainBits.store(gains.source.bitPattern, ordering: .relaxed)
        synthBank.synthGain = gains.synth
        masterMixer.outputVolume = gains.master
        // The pans are the main mixer's input settings, re-applied here so a graph rebuilt for
        // another device gets them back with its gains.
        sourceNode?.pan = gains.stereoSplit ? -1 : 0
        masterMixer.pan = gains.stereoSplit ? 1 : 0
    }
}
