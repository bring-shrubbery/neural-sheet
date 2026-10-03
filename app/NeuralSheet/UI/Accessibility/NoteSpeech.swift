import Foundation
import NeuralSheetCore

/// A note as VoiceOver reads it on the roll (a11y design §2): "C4, Piano, bar 3 beat 2, half a
/// beat" -- the pitch, the instrument, where it starts on the grid and how long it is in the
/// meter's own beats, the words a musician would use rather than seconds.
enum NoteSpeech {
    static func description(of note: NoteEvent, grid: TempoGrid) -> String {
        let pitch = TimeFormat.pitchName(note.pitch)
        let instrument = Instruments.info(forProgram: note.program).name
        // Nudged past the line, as the ruler labels a beat that starts exactly on it.
        let position = grid.barBeat(at: note.startTime + 1e-6)
        let length = length(of: note, grid: grid)

        return String(localized: "\(pitch), \(instrument), bar \(position.bar) beat \(position.beat), \(length)",
                      comment: "VoiceOver: a note on the piano roll; pitch, instrument, where it starts, how long it is, e.g. \"C4, Piano, bar 3 beat 2, half a beat\"")
    }

    /// Quarters, halves and three quarters of a beat in words, whole beats counted, anything
    /// else to a tenth.
    static func length(of note: NoteEvent, grid: TempoGrid) -> String {
        let beatLength = grid.segment(atSeconds: note.startTime).timeSignature.beatLength
        let beats = (grid.quarterBeats(atSeconds: note.endTime) - grid.quarterBeats(atSeconds: note.startTime)) / beatLength
        let quarters = (beats * 4).rounded()

        if abs(beats * 4 - quarters) < 0.2 {
            switch Int(quarters) {
            case 1:
                return String(localized: "a quarter of a beat", comment: "VoiceOver: a note's length")
            case 2:
                return String(localized: "half a beat", comment: "VoiceOver: a note's length")
            case 3:
                return String(localized: "three quarters of a beat", comment: "VoiceOver: a note's length")
            case let whole where whole > 0 && whole % 4 == 0:
                let count = whole / 4

                return String(localized: "\(count) beats", comment: "VoiceOver: a note's length in whole beats")
            default:
                break
            }
        }

        let tenths = beats.formatted(.number.precision(.fractionLength(1)))

        return String(localized: "\(tenths) beats", comment: "VoiceOver: a note's length in beats, to a tenth, e.g. \"1.5 beats\"")
    }
}
