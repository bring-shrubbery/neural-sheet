import Foundation

/// The settings that drop notes as a run lands, and the rule Select Doubtful Notes picks by
/// (confidence design §2). Pure: the app calls it on the model's output at each of the three
/// landings (a full run, each stem, a region) and never on notes already in the document.
public enum NoteFilter {
    /// Below this a note is doubtful, whatever the settings say.
    public static let doubtfulConfidence = 0.5

    /// The choices Settings → Model offers, 0 first for off: seconds, then 0…1.
    public static let minimumLengthChoices: [Double] = [0, 0.02, 0.03, 0.05, 0.075, 0.1]
    public static let minimumConfidenceChoices: [Double] = [0, 0.25, 0.5, 0.75]

    /// Slack on the length comparison, far under the model's 10 ms grid: a note from 1.00 to
    /// 1.05 s is 0.04999… long in binary, and it is a 50 ms note.
    static let lengthTolerance = 1e-9

    /// `notes` without those shorter than `minimumLength` or less sure than
    /// `minimumConfidence`; a note exactly at either threshold stays, a 0 threshold is off, and
    /// a note with no confidence is never dropped for it. Order is kept.
    public static func apply(_ notes: [NoteEvent], minimumLength: Double, minimumConfidence: Double) -> [NoteEvent] {
        guard minimumLength > 0 || minimumConfidence > 0 else { return notes }

        return notes.filter { note in
            !isShort(note, minimumLength: minimumLength) && note.confidenceOrSure >= minimumConfidence
        }
    }

    /// Whether Select Doubtful Notes picks `note`: under ``doubtfulConfidence``, or shorter
    /// than `minimumLength` when that is on.
    public static func isDoubtful(_ note: NoteEvent, minimumLength: Double) -> Bool {
        note.confidenceOrSure < doubtfulConfidence || isShort(note, minimumLength: minimumLength)
    }

    private static func isShort(_ note: NoteEvent, minimumLength: Double) -> Bool {
        minimumLength > 0 && note.endTime - note.startTime < minimumLength - lengthTolerance
    }
}
