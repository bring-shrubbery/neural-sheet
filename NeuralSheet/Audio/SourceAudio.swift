import Foundation
import NeuralSheetCore

/// The loaded take: the playback buffer at the device rate, the 16 kHz mono the model reads, and the
/// peaks the waveform draws from.
///
/// Immutable once built. The playback engine never mutates one — it swaps the whole object — so the
/// render block can read it without any synchronisation beyond the single-word pointer it arrives
/// through.
///
/// `@unchecked Sendable`: every stored property is a `let` and the raw playback storage is written
/// only in `init`. ``peaks`` is itself `@unchecked Sendable` and manages its own access.
///
/// The playback audio lives in ``storage`` alone: the `[[Float]]` it was built from is copied in
/// and let go, not retained beside it, so a take costs one buffer rather than two.
nonisolated final class SourceAudio: @unchecked Sendable {
    /// The rate the playback buffer is at, which is the audio device's rate at the time it was built.
    let deviceRate: Double

    /// What the transcription model reads: mono, 16 kHz, always.
    let mono16k: [Float]

    /// Seconds of audio, measured on the model's copy so it does not move when the device rate does.
    var duration: Double { Double(mono16k.count) / 16000 }

    let peaks: WaveformPeaks

    /// The dropped file's name without its extension, or nil for a recorded take.
    let droppedFileName: String?

    /// Where the audio came from, for re-reading it when a session is restored.
    let sourcePath: URL?

    // MARK: - The render thread's view

    /// Frames in the playback buffer. The playhead wraps here, not at ``duration``: a resample
    /// leaves the two a sample or two apart and the read has to stay inside what was allocated.
    let frameCount: Int

    /// Channels in the playback buffer, at least 1.
    let channelCount: Int

    /// `channelCount × frameCount` floats, planar. Allocated once here and freed in `deinit`, so the
    /// render block indexes raw memory instead of walking a Swift array of arrays.
    private let storage: UnsafeMutableBufferPointer<Float>

    /// - Parameter channels: Playback audio at `deviceRate`, with the source's own channel count.
    ///   Copied into ``storage``; the arrays are not kept.
    init(
        deviceRate: Double,
        channels: [[Float]],
        mono16k: [Float],
        peaks: WaveformPeaks,
        droppedFileName: String?,
        sourcePath: URL?
    ) {
        self.deviceRate = deviceRate
        self.mono16k = mono16k
        self.peaks = peaks
        self.droppedFileName = droppedFileName
        self.sourcePath = sourcePath

        let frames = channels.isEmpty ? 0 : channels.reduce(Int.max) { Swift.min($0, $1.count) }
        self.frameCount = frames
        self.channelCount = Swift.max(1, channels.count)

        storage = UnsafeMutableBufferPointer<Float>.allocate(
            capacity: Swift.max(1, channelCount * frames))
        storage.initialize(repeating: 0)

        if let base = storage.baseAddress {
            for (index, channel) in channels.enumerated() {
                channel.withUnsafeBufferPointer { source in
                    guard let sourceBase = source.baseAddress else { return }
                    (base + index * frames).update(from: sourceBase, count: frames)
                }
            }
        }
    }

    deinit {
        storage.deallocate()
    }

    /// Audio thread. The first sample of `channel`, which the caller has already clamped into
    /// `0..<channelCount`.
    @inline(__always)
    func base(ofChannel channel: Int) -> UnsafePointer<Float> {
        UnsafePointer(storage.baseAddress.unsafelyUnwrapped + channel * frameCount)
    }

    /// The same take with its playback buffer converted to another device rate. The model's copy and
    /// the peaks are shared rather than rebuilt: neither depends on the device.
    ///
    /// Main thread, and allocating: the channels are read back out of ``storage`` for the
    /// resampler and dropped again once the new take has copied its own in.
    func resampled(to rate: Double) -> SourceAudio {
        guard rate != deviceRate, frameCount > 0 else { return self }

        let channels = (0..<channelCount).map { channel in
            [Float](UnsafeBufferPointer(start: base(ofChannel: channel), count: frameCount))
        }

        return SourceAudio(
            deviceRate: rate,
            channels: Resampler.resample(channels: channels, from: deviceRate, to: rate),
            mono16k: mono16k,
            peaks: peaks,
            droppedFileName: droppedFileName,
            sourcePath: sourcePath
        )
    }
}
