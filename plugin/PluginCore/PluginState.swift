import Foundation
import NeuralSheetCore

/// What the plugin keeps in the host's project (Audio Unit design §2, "State"): the take as
/// Apple Lossless, the notes as the app's project keeps them, and the choices around them -- the
/// model, the instruments, Stems, the mix, the master, the strips and Send MIDI to host. Restoring
/// it rebuilds the roll and the playback without transcribing again.
///
/// Coded as a binary property list, so the ALAC bytes are stored as they are rather than as
/// Base64. ``decode(_:)`` answers nil rather than throwing for anything it cannot use -- another
/// format version, a damaged or truncated blob -- and the plugin then starts empty.
///
/// Free of AU types (design §3).
nonisolated struct PluginState: Codable, Equatable, Sendable {
    /// Bumped whenever an older plugin would misread the state; a state of any other version is
    /// not restored.
    static let currentVersion = 1

    /// The longest take kept: ten minutes, the capture ring's length. A longer one (a host rate
    /// change made the ring longer than it was) is stored cut there, and ``Take/truncated`` says so.
    static let maximumTakeSeconds: Double = 600

    /// The take, at the host's rate when it was captured.
    struct Take: Codable, Equatable, Sendable {
        /// An ALAC CAF (``TakeALAC``).
        var alac: Data
        var sampleRate: Double
        var channelCount: Int
        /// Frames per channel in ``alac``.
        var frameCount: Int
        /// The host's sample time of the first frame (``CapturedTake/startSampleTime``).
        var startSampleTime: Double?
        /// The capture was longer than ``PluginState/maximumTakeSeconds`` and is stored cut there.
        var truncated: Bool
    }

    var version = PluginState.currentVersion
    var take: Take?
    /// The finished run's notes, as a project's `transcription.json` holds them; nil before one.
    var transcription: ProjectTranscription?
    /// The model picked in the view; nil follows the app's setting.
    var modelSize: ModelSize?
    /// `InstrumentGroup` raw values; empty is Automatic.
    var selectedGroups: [Int32] = []
    var separateStems = false
    /// The ORIG / MIDI crossfade, 0…1.
    var mix = 0.5
    var masterGainDb = 0.0
    /// The strips, keyed by program, as a project's mixer.
    var mixer: [Int: InstrumentChannelSettings] = [:]
    var sendsMIDI = false

    // MARK: - Coding

    private struct Header: Decodable {
        var version: Int
    }

    /// The state as bytes, nil when it cannot be coded.
    func encode() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    /// The state in `data`, or nil when it is not a state of ``currentVersion``.
    static func decode(_ data: Data) -> PluginState? {
        let decoder = PropertyListDecoder()

        guard let header = try? decoder.decode(Header.self, from: data), header.version == currentVersion else {
            return nil
        }

        return try? decoder.decode(PluginState.self, from: data)
    }
}

// MARK: - The take

extension PluginState.Take {
    /// `take` as ALAC, cut at `maximumSeconds`; nil for an empty take or when the encoder fails.
    /// Seconds for a long take: off the main thread.
    nonisolated static func make(from take: CapturedTake,
                                 maximumSeconds: Double = PluginState.maximumTakeSeconds) -> PluginState.Take? {
        let source = take.source
        let limit = Int((maximumSeconds * take.sampleRate).rounded(.down))
        let frames = min(source.frameCount, limit)

        guard let alac = try? TakeALAC.encode(frames: frames, channels: source.channelCount, sampleRate: take.sampleRate,
                                              channel: { source.base(ofChannel: $0) })
        else { return nil }

        return PluginState.Take(alac: alac, sampleRate: take.sampleRate, channelCount: source.channelCount,
                                frameCount: frames, startSampleTime: take.startSampleTime,
                                truncated: frames < source.frameCount)
    }

    /// The take again, its 16 kHz copy and peaks rebuilt as a capture builds them; nil when the
    /// bytes do not decode to what the fields say. Off the main thread.
    nonisolated func restore() -> CapturedTake? {
        guard let channels = TakeALAC.decode(alac, sampleRate: sampleRate, channels: channelCount, frames: frameCount)
        else { return nil }

        return CapturedTake.make(channels: channels, sampleRate: sampleRate, startSampleTime: startSampleTime)
    }
}
