import Foundation
import NeuralSheetCore

/// The tempo and the key from the music rather than from typing (tempo design §4, key design
/// §4): taps along with the take set the BPM; a detection over the take's audio sets the tempo
/// map, the downbeat and, when the accents are clear, the meter (tempo map design §4), and over
/// the transcription's notes the key and then the chords (chord symbols design §2).
extension AppModel {
    // MARK: - Tap

    /// The Tap button and the `t` key: a press in time with playback. Refused while the
    /// transport stands still, since the taps are on the take's clock and a stopped clock has
    /// no intervals. Once two taps are in, the tempo of the segment under the playhead follows
    /// them (tempo map design §4).
    func tap() {
        guard state.canPlay, isPlaying else { return }

        if let bpm = tapTempo.tap(at: playheadSeconds) {
            setGridBpm(bpm)
        }
    }

    // MARK: - Detect

    /// The Detect button: the take's tempo map and downbeat, found off the main thread and
    /// written to the grid when they land, unless the take has changed underneath, and then the
    /// key and the chords from the notes. Nothing to find is said so in the standard dialog. A map someone has
    /// shaped (a change, or a meter other than 4/4) is asked about first, the way Revert asks.
    func detectTempo() {
        guard source != nil, !isDetectingTempo else { return }

        let grid = editor.grid
        let isShaped = grid.segments.count > 1 || grid.segments.contains { $0.timeSignature != .common }

        guard isShaped, let presentConfirm else {
            runTempoDetection()
            return
        }

        presentConfirm("Replace the tempo map?",
                       "Detect replaces the tempo changes and the time signature with what it finds in the take.",
                       "Replace") { [weak self] confirmed in
            if confirmed {
                self?.runTempoDetection()
            }
        }
    }

    private func runTempoDetection() {
        guard let source, !isDetectingTempo else { return }

        isDetectingTempo = true

        // The model's mono copy is immutable, so the analysis can read it off the main actor.
        let mono = source.mono16k
        // The meter the bars are counted in when the accents do not settle it.
        let meter = editor.grid.timeSignature

        Task.detached(priority: .userInitiated) { [weak self] in
            let estimate = TempoEstimator.estimate(mono16k: mono, meter: meter)

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

        // The whole map in one step, the meter with it when the accents were sure.
        editor.grid.replaceMap(estimate.segments, offsetSeconds: estimate.downbeatSeconds)
        detectKey()
        // After the key, which spells them and tips a close call, on the new bars.
        detectChords(reportsNothing: false)
    }

    /// The key of the transcription's notes (key design §2), when there are melodic notes to
    /// read it from; otherwise the key is left as it is.
    func detectKey() {
        guard let document, let key = KeyEstimator.estimate(notes: document.events) else { return }

        setKey(key)
    }
}
