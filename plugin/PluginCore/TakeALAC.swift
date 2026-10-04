import AVFoundation
import Foundation

/// The take as Apple Lossless, for the plugin's saved state (Audio Unit design §2, "State").
///
/// `AVAudioFile` writes and reads ALAC only through a file, so the bytes pass through a CAF in the
/// temporary directory (the extension's own, inside its sandbox), removed on every path. CAF
/// rather than MPEG-4: it carries ALAC with no edit list or priming to trim, so the frame count
/// read back is the one written.
///
/// ALAC codes integers. The take is written from 32-bit floats at a 24-bit source depth: a
/// sample on the 24-bit grid inside full scale -- anything a 24-bit interface records, and every
/// sample after one round trip -- comes back bit for bit; any other float is rounded to the grid
/// (within 2⁻²⁴, −144 dBFS), and a float past full scale is clipped to it. 24 bits rather than 32
/// keeps a ten-minute stereo take near 100 MB rather than 130 in the host's project.
///
/// Free of AU types (design §3). Slow and allocating; never the render thread's.
nonisolated enum TakeALAC {
    /// The source depth the encoder is given.
    static let bitDepth = 24

    /// Frames per write and read, so a ten-minute take never needs a second copy of itself.
    private static let blockFrames = 65_536

    enum Failure: Error {
        case noFrames
        case format
    }

    /// The first `frames` frames of `channels` planar channels (each read through `channel(c)`) at
    /// `sampleRate`, as the bytes of an ALAC CAF.
    static func encode(frames: Int, channels: Int, sampleRate: Double,
                       channel: (Int) -> UnsafePointer<Float>) throws -> Data {
        guard frames > 0, channels > 0, sampleRate > 0 else { throw Failure.noFrames }

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // The file is closed when it goes out of scope, before the bytes are read back.
        try {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: bitDepth,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(blockFrames)),
                let data = buffer.floatChannelData
            else { throw Failure.format }

            var written = 0
            while written < frames {
                let count = min(blockFrames, frames - written)
                for index in 0..<channels {
                    data[index].update(from: channel(index) + written, count: count)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                written += count
            }
        }()

        return try Data(contentsOf: url)
    }

    /// The planar channels in `data`, or nil when it is not an ALAC file of `channels` channels
    /// at `sampleRate` holding `frames` frames.
    static func decode(_ data: Data, sampleRate: Double, channels: Int, frames: Int) -> [[Float]]? {
        guard frames > 0, channels > 0 else { return nil }

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        guard (try? data.write(to: url)) != nil,
            let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
            file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless,
            file.processingFormat.sampleRate == sampleRate,
            Int(file.processingFormat.channelCount) == channels,
            file.length == AVAudioFramePosition(frames),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(blockFrames)),
            let samples = buffer.floatChannelData
        else { return nil }

        var output = [[Float]](repeating: [], count: channels)
        for index in 0..<channels { output[index].reserveCapacity(frames) }

        while output[0].count < frames {
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(min(blockFrames, frames - output[0].count)))) != nil,
                buffer.frameLength > 0
            else { return nil }

            let count = Int(buffer.frameLength)
            for index in 0..<channels {
                output[index].append(contentsOf: UnsafeBufferPointer(start: samples[index], count: count))
            }
        }

        return output
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NeuralSheetTake-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }
}
