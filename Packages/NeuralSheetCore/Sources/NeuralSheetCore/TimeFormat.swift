import Foundation

/// The app's text formatters: every readout that turns a number into a label goes through here so
/// the same value reads the same way everywhere.
public enum TimeFormat {
    /// Transport position and total, `mm:ss.dd` (hundredths, truncated).
    public static func transport(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00.00" }
        let hundredths = Int((seconds * 100).rounded(.down))
        return String(
            format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }

    /// Shown in place of the total while there is no audio.
    public static let transportPlaceholder = "--:--.--"

    /// Time-ruler tick label, `m:ss` (minutes unpadded, seconds zero-padded).
    public static func ruler(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Volume readout, one decimal, e.g. `-3.0`.
    public static func decibels(_ db: Double) -> String {
        String(format: "%.1f", db)
    }

    /// Duration body of the status bar's `"<dd.dd> s"` segment, e.g. `12.34`.
    public static func seconds2(_ s: Double) -> String {
        String(format: "%.2f", s)
    }

    /// Model size, `"2.7 GB"` from a billion bytes up, `"618 MB"` below.
    public static func fileSize(bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e9 {
            return String(format: "%.1f GB", value / 1e9)
        }
        return "\(Int((value / 1e6).rounded())) MB"
    }

    private static let pitchClassNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// MIDI note number as a note name, e.g. `C4` for 60.
    public static func pitchName(_ midi: Int) -> String {
        let pitchClass = ((midi % 12) + 12) % 12
        let octave = (midi - pitchClass) / 12 - 1
        return "\(pitchClassNames[pitchClass])\(octave)"
    }
}
