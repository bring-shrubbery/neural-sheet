import Foundation
import NeuralSheetCore

/// The tempo and the key from the music rather than from typing (tempo design §4, key design
/// §4): taps along with the take set the BPM; a detection over the take's audio sets the BPM and
/// the downbeat, and over the transcription's notes the key.
extension AppModel {
    // MARK: - Tap

    /// The Tap button and the `t` key: a press in time with playback. Refused while the
    /// transport stands still, since the taps are on the take's clock and a stopped clock has
    /// no intervals. Once two taps are in, the grid's BPM follows them.
    func tap() {
        guard state.canPlay, isPlaying else { return }

        if let bpm = tapTempo.tap(at: playheadSeconds) {
            setGridBpm(bpm)
        }
    }

    // MARK: - Detect

    /// The Detect button: the take's tempo and downbeat, found off the main thread and written
    /// to the grid when they land, unless the take has changed underneath, and then the key
    /// from the notes. Nothing to find is said so in the standard dialog.
    func detectTempo() {
        guard let source, !isDetectingTempo else { return }

        isDetectingTempo = true

        // The model's mono copy is immutable, so the analysis can read it off the main actor.
        let mono = source.mono16k

        Task.detached(priority: .userInitiated) { [weak self] in
            let estimate = TempoEstimator.estimate(mono16k: mono)

            await MainActor.run { [weak self] in
                self?.tempoDetectionDidFinish(estimate, for: source)
            }
        }
    }

    /// Back on the main actor: the result written to the grid, unless the take has changed
    /// underneath, or the dialog.
    private func tempoDetectionDidFinish(_ estimate: TempoEstimate?, for analysed: SourceAudio) {
        isDetectingTempo = false

        // A take swapped mid-analysis is not the one this describes.
        guard source === analysed else { return }

        guard let estimate else {
            showError("Could not detect a tempo.", "The take is too short or has no clear beat.")
            return
        }

        setGridBpm(estimate.bpm)
        setGridOffset(estimate.downbeatSeconds)
        detectKey()
    }

    /// The key of the transcription's notes (key design §2), when there are melodic notes to
    /// read it from; otherwise the key is left as it is.
    func detectKey() {
        guard let document, let key = KeyEstimator.estimate(notes: document.events) else { return }

        setKey(key)
    }
}
