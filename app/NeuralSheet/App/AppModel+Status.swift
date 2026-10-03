import Foundation
import NeuralSheetCore

/// What the toolbar, the roll and the status bar derive from the state: which commands are
/// available, the Transcribe label, the time readout and the status line's counts.
extension AppModel {
    /// Record starts a take from empty, and stops one in progress or cancels its count-in.
    var canRecord: Bool { (state == .empty && importJob == nil) || state == .recording || state == .countingIn }

    var canTranscribe: Bool {
        state == .audioLoaded && modelSize != nil && !jobActive && importJob == nil && stemsExport == nil
    }

    /// Both MIDI exits: only a finished transcription, never a half-decoded one (§6.1).
    var canExport: Bool { state == .populated }

    /// Names the selection only once there is audio to run it on (`_layOutTranscribeButton`):
    /// with nothing loaded there is nothing to be specific about, so it names the action only.
    var transcribeLabel: String {
        switch state == .audioLoaded ? selectedGroups.count : 0 {
        case 0: String(localized: "Transcribe", comment: "The roll's call to action with no instruments chosen")
        case let n: String(localized: "Transcribe \(n) instruments", comment: "The roll's call to action, with how many instruments are chosen")
        }
    }

    var timeReadout: (position: String, total: String) {
        (TimeFormat.transport(playheadSeconds),
         duration > 0 ? TimeFormat.transport(duration) : TimeFormat.transportPlaceholder)
    }

    /// What the status bar counts. The range is nil until there is a note to range over, so a
    /// placeholder strip does not read as "C-1 - C-1" (§1.7).
    var statusLine: (instruments: Int, notes: Int, lowest: Int?, highest: Int?) {
        let populated = mixer.entries.filter { $0.noteCount > 0 }
        let lowest = populated.map(\.lowestPitch).min()
        let highest = populated.map(\.highestPitch).max()

        return (mixer.entries.count, notes.count, lowest, highest)
    }
}
