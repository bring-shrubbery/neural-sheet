import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization

/// The take the render block reads: swapping it in, handing over the loop, and keeping a replaced
/// take alive until no render block can be inside it. Main thread.
nonisolated extension PlaybackEngine {
    /// How long a replaced take is kept alive after the box stops pointing at it. Orders of
    /// magnitude more than one render cycle, which is all the block needs.
    private static let retirementSeconds = 0.5

    /// Swaps in a new take, or clears the current one. The transport stops and rewinds either way.
    ///
    /// Re-resamples when the take was built for a different device rate, which is what happens when
    /// a session is restored onto different hardware or the output device changes mid-session.
    func setSource(_ audio: SourceAudio?) {
        pause()

        let prepared = audio.map { $0.deviceRate == sampleRate ? $0 : $0.resampled(to: sampleRate) }
        let retiring = currentSource

        currentSource = prepared
        state.source.pointee = prepared.map { Unmanaged.passUnretained($0) }

        supersedePendingWrap()
        state.playheadFrames.store(0, ordering: .relaxed)
        // As a seek rather than a store into the frames alone: the block keeps the exact
        // position in a field of its own, and only a seek reaches it.
        state.pendingSeek.store(0, ordering: .relaxed)
        synthBank.scheduler.seek(toSeconds: 0)
        synthBank.allNotesOff()

        // The window is clamped to the take, so a new take means clamping it again.
        applyLoop()

        retire(retiring)
    }

    /// Hands the render block the loop as frames at the current rate, clamped to the current
    /// take; 0 -- no loop -- with no take or a window that does not fit it.
    // Internal: the loop's didSet and rebuildGraph call it.
    func applyLoop() {
        let window = loop.flatMap { seconds in
            currentSource.flatMap { source in
                LoopWindow(seconds: seconds, sampleRate: sampleRate, frameCount: source.frameCount)
            }
        }

        state.loopBits.store(window?.packed ?? 0, ordering: .relaxed)
    }

    /// A wrap the poll has not picked up yet is superseded by an explicit seek or a new take: the
    /// transport is where it has just been put, not at an end it passed a few milliseconds ago.
    /// Without this the poll would re-anchor the scheduler and announce the wrap up to 33 ms late,
    /// on top of a position the user had already chosen.
    // Internal: PlaybackEngine+Transport.swift calls it.
    func supersedePendingWrap() {
        lastWrapGeneration = state.wrapGeneration.load(ordering: .relaxed)
    }

    /// Holds a replaced take until any render block that saw it has long since returned.
    private func retire(_ source: SourceAudio?) {
        guard let source else { return }

        retiredSources.append(source)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retirementSeconds) { [weak self] in
            guard let self else { return }
            if let index = self.retiredSources.firstIndex(where: { $0 === source }) {
                self.retiredSources.remove(at: index)
            }
        }
    }
}
