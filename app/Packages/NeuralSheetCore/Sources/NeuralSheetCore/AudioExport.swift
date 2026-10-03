import AudioToolbox
import Foundation

/// File → Export Audio…'s *What* (audio export design §2).
public enum AudioExportWhat: String, Codable, CaseIterable, Sendable {
    /// The synth alone, at mix 1.0 and the master at 0 dB.
    case midi
    /// The take and the synth as playback has them: the mix, the master, the split.
    case mixAsHeard
    /// The take's own channels, clipped to the range, no synth.
    case original

    public var title: String {
        switch self {
        case .midi: "MIDI only"
        case .mixAsHeard: "Original + MIDI as heard"
        case .original: "Original only"
        }
    }

    /// Whether the synth is rendered at all, and so whether the file gets a release tail.
    public var includesSynth: Bool { self != .original }

    /// Whether the take's channels are in the file.
    public var includesOriginal: Bool { self != .midi }
}

/// File → Export Audio…'s *Format* (audio export design §2): the container, the codec and what
/// `AVAudioFile(forWriting:settings:…)` is handed for it.
public enum AudioExportFormat: String, Codable, CaseIterable, Sendable {
    case wav24
    case aiff24
    case m4a

    public var title: String {
        switch self {
        case .wav24: "WAV 24-bit"
        case .aiff24: "AIFF 24-bit"
        case .m4a: "M4A (AAC 256 kb/s)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wav24: "wav"
        case .aiff24: "aiff"
        case .m4a: "m4a"
        }
    }

    /// The AAC bit rate the M4A is written at.
    public static let aacBitRate = 256_000

    /// The `AVAudioFile` settings: 24-bit integer PCM (little-endian in a WAV, big-endian in an
    /// AIFF, as each container wants), or AAC at 256 kb/s. The keys are AVFoundation's
    /// (`AVFormatIDKey` …), spelled out so this package needs no AVFoundation.
    public func fileSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        var settings: [String: Any] = [
            "AVSampleRateKey": sampleRate,
            "AVNumberOfChannelsKey": channels,
        ]

        switch self {
        case .wav24, .aiff24:
            settings["AVFormatIDKey"] = kAudioFormatLinearPCM
            settings["AVLinearPCMBitDepthKey"] = 24
            settings["AVLinearPCMIsFloatKey"] = false
            settings["AVLinearPCMIsBigEndianKey"] = self == .aiff24
            settings["AVLinearPCMIsNonInterleaved"] = false

        case .m4a:
            settings["AVFormatIDKey"] = kAudioFormatMPEG4AAC
            settings["AVEncoderBitRateKey"] = AudioExportFormat.aacBitRate
        }

        return settings
    }

    /// `"<take name>.<extension>"`, the save panel's default name.
    public func fileName(takeName: String) -> String {
        "\(StemNames.sanitized(takeName)).\(fileExtension)"
    }
}

/// What one render is asked for (audio export design §2).
public struct RenderSpec: Equatable, Sendable {
    public var what: AudioExportWhat
    /// Seconds of the take: the whole of it, or the marked range.
    public var range: ClosedRange<Double>
    public var format: AudioExportFormat

    public init(what: AudioExportWhat, range: ClosedRange<Double>, format: AudioExportFormat) {
        self.what = what
        self.range = range
        self.format = format
    }

    /// Where the transport stops (audio export design §2): the end of the range, except that MIDI
    /// only stops at the last note-off inside it, so the file is as long as the last note plus
    /// its tail (issue #22, acceptance). `notes` are the notes' times in seconds; notes
    /// starting at or past the range's end do not count.
    public func transportEnd(notes: [(start: Double, end: Double)]) -> Double {
        guard what == .midi else { return range.upperBound }

        let last = notes.filter { $0.start < range.upperBound && $0.end > range.lowerBound }.map(\.end).max()

        guard let last else { return range.upperBound }

        return min(max(last, range.lowerBound), range.upperBound)
    }
}

/// The render's release tail (audio export design §2): after the transport stops, blocks go on
/// being rendered until the first one whose peak is below −90 dBFS, and never more than 2 s of
/// them.
public enum RenderTail {
    /// The frames the offline engine renders at a time, and the unit the tail is measured in.
    public static let blockFrames = 4096

    public static let silenceDb = -90.0

    /// −90 dBFS as a linear peak.
    public static let silencePeak = Float(pow(10.0, silenceDb / 20.0))

    public static let maxSeconds = 2.0

    /// Whether a tail block with this peak ends the file.
    public static func isSilent(peak: Float) -> Bool {
        peak < silencePeak
    }

    /// The most tail frames at `sampleRate`.
    public static func maxFrames(sampleRate: Double) -> Int {
        Int((maxSeconds * sampleRate).rounded())
    }
}

/// The names of the stems a separation keeps and Export Stems… writes (audio export design §2).
public enum StemNames {
    /// The stems in the order the separator produces them (drums, bass, other, vocals).
    public static let displayNames = ["Drums", "Bass", "Other", "Vocals"]

    /// The order the files are written and listed in: drums, bass, vocals, other.
    public static let exportOrder = [0, 1, 3, 2]

    /// The 24-bit `.caf` a kept separation holds for stem `index`: `Drums.caf` ….
    public static func cacheFileName(stem index: Int) -> String {
        "\(displayNames[index]).caf"
    }

    /// `"<take name> - Drums.wav"` ….
    public static func exportFileName(takeName: String, stem index: Int) -> String {
        "\(sanitized(takeName)) - \(displayNames[index]).wav"
    }

    /// A name a file can carry: a path separator or a colon would put it elsewhere or be refused
    /// by the Finder, and an empty name would be only the suffix.
    public static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Recording" : cleaned
    }
}
