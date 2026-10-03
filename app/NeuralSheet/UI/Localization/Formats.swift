import Foundation
import NeuralSheetCore

/// The readouts that turn a number into text, in the user's locale (a11y and localization design
/// §2): a decimal comma in German, the percent sign where the language puts it. Each mirrors the
/// `TimeFormat` rule it replaces on screen -- the same digits, the same rounding -- so in English
/// nothing changes. The transport clock and the pitch names stay `TimeFormat`'s: `m:ss.dd` and
/// `C4` read the same in every language.
nonisolated enum Formats {
    /// `-3.0`, `-3,0`: a level in dB, one decimal.
    static func decibels(_ db: Double) -> String {
        db.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    /// `12.34`, `12,34`: seconds to the hundredth.
    static func seconds2(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(2)).grouping(.never))
    }

    /// `75%`, `75 %`.
    static func percent(_ value: Int) -> String {
        value.formatted(.percent)
    }

    /// A number to `decimals` places without grouping, as the editable fields show and parse it.
    static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }

    /// A typed number, in the locale's own notation or the C one: `1,5` and `1.5` both read in
    /// German, so a value pasted from elsewhere still lands.
    static func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if let value = try? Double(trimmed, format: .number.grouping(.never)) {
            return value
        }

        return Double(trimmed)
    }

    /// `90`, `92.5`, `92,5`: a tempo to the tenth, whole tempos without a decimal, as
    /// `MusicXMLWriter.tempoText` writes it in the file.
    static func tempo(_ bpm: Double) -> String {
        let tenths = (bpm * 10).rounded() / 10

        return tenths.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// `2.7 GB` from a billion bytes up, `618 MB` below, as `TimeFormat.fileSize` has it.
    static func fileSize(bytes: Int64) -> String {
        let value = Double(bytes)

        if value >= 1e9 {
            let gigabytes = (value / 1e9).formatted(.number.precision(.fractionLength(1)).grouping(.never))

            return String(localized: "\(gigabytes) GB", comment: "A file size in gigabytes, e.g. \"2.7 GB\"")
        }

        let megabytes = Int((value / 1e6).rounded())

        return String(localized: "\(megabytes) MB", comment: "A file size in megabytes, e.g. \"618 MB\"")
    }
}
