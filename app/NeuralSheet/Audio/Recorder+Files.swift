import AVFoundation
import Foundation

/// The two WAVs a take is written to: their format, the buffers handed to them and their names.
nonisolated extension Recorder {
    /// A 16-bit little-endian PCM WAV, which the extension picks out of the settings.
    ///
    /// The file is written through a float `processingFormat`: `AVAudioFile` converts on the way in,
    /// so nothing here has to think about integer scaling or clipping.
    static func settings(rate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// A float buffer over `channels`, for handing to an ``AVAudioFile``.
    static func buffer(channels: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !channels.isEmpty else { return nil }

        let frames = channels.reduce(Int.max) { Swift.min($0, $1.count) }

        guard frames > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let data = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)

        for (index, channel) in channels.enumerated() where index < Int(format.channelCount) {
            channel.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                data[index].update(from: base, count: frames)
            }
        }

        // A buffer arrives uninitialised, so a device that lost a channel mid-take would otherwise
        // write whatever was in that memory into the file. Clamped, because a caller may hand over
        // more channels than the format takes, and `5..<2` is a trap rather than an empty range.
        for index in Swift.min(channels.count, Int(format.channelCount))..<Int(format.channelCount) {
            data[index].update(repeating: 0, count: frames)
        }

        return buffer
    }

    /// `YYYY-MM-DD_HH-MM-SS`, in the user's own time zone: these names are read by people.
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// The pair of names for a new take, with `_1`, `_2`… until neither exists.
    ///
    /// The suffix moves both names together, so a take's two files always match -- a second take
    /// inside the same second cannot end up sharing one of them.
    static func fileURLs(in directory: URL, timestamp: String)
        -> (native: URL, downsampled: URL)
    {
        let manager = FileManager.default
        var suffix = ""
        var index = 1

        while true {
            let stem = "\(filenamePrefix)\(timestamp)\(suffix)"
            let native = directory.appendingPathComponent("\(stem).wav")
            let downsampled = directory.appendingPathComponent("\(stem)_downsampled.wav")

            if !manager.fileExists(atPath: native.path),
                !manager.fileExists(atPath: downsampled.path)
            {
                return (native, downsampled)
            }

            suffix = "_\(index)"
            index += 1
        }
    }
}
