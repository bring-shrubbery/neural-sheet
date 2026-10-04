import Foundation
import NeuralSheetCore

/// A capture drained from the ring and turned into the app's take (Audio Unit design §2, "Audio
/// path"): the channels at the host's rate as the playback buffer, the 16 kHz mono the model
/// reads, and the waveform's peaks, built the way `AudioFileLoader` builds a dropped file's.
///
/// Free of AU types (design §3).
nonisolated struct CapturedTake: Sendable {
    /// The take, as the app and the engine read one. Its `deviceRate` is the host's rate.
    let source: SourceAudio

    /// The host's `mSampleTime` of the take's first frame, nil when the render block never saw a
    /// cycle (a capture stopped before the host rendered). What a playhead that follows the host
    /// subtracts (design §2, "Playhead").
    let startSampleTime: Double?

    /// Frames a full ring turned away during the capture; 0 unless the main thread stalled.
    let droppedFrames: Int

    /// Frames per channel at the host's rate.
    var frameCount: Int { source.frameCount }

    /// The host's rate.
    var sampleRate: Double { source.deviceRate }

    /// Seconds at the host's rate.
    var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Builds the take from planar channels at `sampleRate`, or nil when there are no frames.
    /// Slow and allocating (a ten-minute take resamples for about a second); not the render
    /// thread's.
    static func make(channels: [[Float]], sampleRate: Double, startSampleTime: Double?, droppedFrames: Int = 0)
        -> CapturedTake?
    {
        guard sampleRate > 0, let frames = channels.map(\.count).min(), frames > 0 else { return nil }

        let mono16k = Resampler.toMono16k(channels: channels, sourceRate: sampleRate)
        let peaks = WaveformPeaks()
        peaks.build(from: mono16k)

        let source = SourceAudio(
            deviceRate: sampleRate,
            channels: channels,
            mono16k: mono16k,
            peaks: peaks,
            droppedFileName: nil,
            sourcePath: nil
        )

        return CapturedTake(source: source, startSampleTime: startSampleTime, droppedFrames: droppedFrames)
    }
}
