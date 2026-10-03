import AVFoundation
import Foundation
import Synchronization

/// The transport: play, pause, stop and seek, and the playhead and master level the main thread
/// reads off the render state. Main thread.
nonisolated extension PlaybackEngine {
    var isPlaying: Bool { state.playing.load(ordering: .relaxed) }

    /// Whether the AVAudioEngine is actually rendering, whatever was asked of it.
    var isRunning: Bool { engine.isRunning }

    func play() {
        // An audition still sounding holds the synth side at unity; the take must play under the
        // crossfade that is set.
        synthBank.stopAudition()
        // A wrap the poll has not picked up yet belongs to the run that just ended: without this,
        // pressing play right after the take finished would immediately re-anchor and announce it.
        supersedePendingWrap()
        // The MIDI output's channels get their programs and controllers ahead of the first note
        // (MIDI out design §2).
        synthBank.midiOut.resendControls()
        state.playing.store(true, ordering: .relaxed)
        retryStartIfNeeded()
    }

    func pause() {
        state.playing.store(false, ordering: .relaxed)
        synthBank.scheduler.requestAllNotesOff()
        synthBank.allNotesOff()
        // The synths' CC 123 does not reach a MIDI destination (MIDI out design §2).
        synthBank.midiOut.panic()
    }

    /// Pause and rewind, which is what the Back button does.
    func stop() {
        pause()
        setPlayhead(frames: 0, seconds: 0)
    }

    /// Ignored unless `0 <= seconds < duration`, exactly as the C++ player does it: a click past the
    /// end of the take is not a seek to the end, it is nothing.
    func seek(seconds: Double) {
        guard let source = currentSource, seconds >= 0, seconds < source.duration else { return }

        let frames = Int((seconds * sampleRate).rounded())
        setPlayhead(frames: max(0, min(frames, max(0, source.frameCount - 1))), seconds: seconds)
    }

    /// Where the playhead is now. A seek that the render block has not picked up yet reads as
    /// already applied, so the UI does not flick back for a block.
    var playheadSeconds: Double {
        let pending = state.pendingSeek.load(ordering: .relaxed)
        let frames = pending >= 0 ? pending : state.playheadFrames.load(ordering: .relaxed)

        return Double(frames) / sampleRate
    }

    /// The master meter's level after the fader.
    var masterLevelDb: Double { Double(bitPattern: state.masterLevelBits.load(ordering: .relaxed)) }

    private func setPlayhead(frames: Int, seconds: Double) {
        supersedePendingWrap()
        state.pendingSeek.store(frames, ordering: .relaxed)
        synthBank.scheduler.seek(toSeconds: seconds)
        // The scheduler's note-offs are not enough on their own: drums are one-shot and the synth
        // ignores a note-off for them, so a seek has to silence the synth directly. The MIDI
        // output the same, and its channels set up again for the notes from the new position.
        synthBank.allNotesOff()
        synthBank.midiOut.panic()
        synthBank.midiOut.resendControls()
    }
}
