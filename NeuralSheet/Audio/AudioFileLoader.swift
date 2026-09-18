import AVFoundation
import Foundation
import NeuralSheetCore

/// Turns a file on disk into a ``SourceAudio``.
///
/// Everything AVFoundation can decode goes through `AVAudioFile`; Ogg Vorbis, which it cannot, goes
/// through the vendored stb_vorbis. Either way the result is float channels at the file's own rate,
/// which are then converted twice: to the device rate for playback and to 16 kHz mono for the model.
nonisolated enum AudioFileLoader {
    /// The extensions the drop target and the file chooser accept, lower-cased, in the order the
    /// original listed them in its "Could not load the file." message: the hard-coded ".mp3",
    /// then each registered JUCE format's own list (`WavAudioFormat` ".wav .bwf", Aiff, Flac, Ogg).
    static let acceptedExtensions = ["mp3", "wav", "bwf", "aiff", "aif", "flac", "ogg"]

    nonisolated enum LoadError: Error {
        /// The file is not one of ``acceptedExtensions``.
        case unsupportedExtension
        /// The extension was right but nothing could be read out of the file.
        case decodeFailed
    }

    /// Reads `url` and returns it ready to play at `deviceRate` and ready to transcribe at 16 kHz.
    ///
    /// Slow and allocating: the message thread's, off the main queue for a long file.
    static func load(url: URL, deviceRate: Double) throws -> SourceAudio {
        let ext = url.pathExtension.lowercased()

        guard acceptedExtensions.contains(ext) else { throw LoadError.unsupportedExtension }

        let decoded = try decode(url: url)

        guard !decoded.channels.isEmpty, decoded.sampleRate > 0,
            decoded.channels.contains(where: { !$0.isEmpty })
        else { throw LoadError.decodeFailed }

        let playback =
            decoded.sampleRate == deviceRate
            ? decoded.channels
            : Resampler.resample(channels: decoded.channels, from: decoded.sampleRate, to: deviceRate)

        let peaks = WaveformPeaks()
        let mono16k = Resampler.toMono16k(channels: decoded.channels, sourceRate: decoded.sampleRate)
        peaks.build(from: mono16k)

        return SourceAudio(
            deviceRate: deviceRate,
            channels: playback,
            mono16k: mono16k,
            peaks: peaks,
            droppedFileName: url.deletingPathExtension().lastPathComponent,
            sourcePath: url
        )
    }

    // MARK: - Decoders

    struct Decoded {
        var channels: [[Float]]
        var sampleRate: Double
    }

    /// The file's own samples at its own rate, with none of ``load(url:deviceRate:)``'s conversions.
    ///
    /// What the recorder's read-back wants: it has one file to play and another to transcribe, so
    /// building 16 kHz mono and peaks out of each of them would be work thrown away.
    static func decode(url: URL) throws -> Decoded {
        url.pathExtension.lowercased() == "ogg"
            ? try decodeOgg(url: url) : try decodeWithAVFoundation(url: url)
    }

    /// mp3 / wav / bwf / aiff / aif / flac. `processingFormat` is always deinterleaved float32, so the
    /// channel pointers come out of the buffer as they are.
    private static func decodeWithAVFoundation(url: URL) throws -> Decoded {
        guard let file = try? AVAudioFile(forReading: url) else { throw LoadError.decodeFailed }

        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)

        guard frames > 0, format.channelCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw LoadError.decodeFailed }

        do {
            try file.read(into: buffer)
        } catch {
            throw LoadError.decodeFailed
        }

        guard let data = buffer.floatChannelData else { throw LoadError.decodeFailed }

        let count = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { channel in
            [Float](UnsafeBufferPointer(start: data[channel], count: count))
        }

        return Decoded(channels: channels, sampleRate: format.sampleRate)
    }

    /// Ogg Vorbis through stb_vorbis, which hands back one interleaved block of 16-bit samples that
    /// this call owns and has to free.
    private static func decodeOgg(url: URL) throws -> Decoded {
        var channelCount: Int32 = 0
        var sampleRate: Int32 = 0
        var output: UnsafeMutablePointer<Int16>?

        let frames = url.path.withCString { path in
            stb_vorbis_decode_filename(path, &channelCount, &sampleRate, &output)
        }

        guard frames > 0, channelCount > 0, sampleRate > 0, let samples = output else {
            if let output { free(output) }
            throw LoadError.decodeFailed
        }

        defer { free(samples) }

        let frameCount = Int(frames)
        let stride = Int(channelCount)
        // The same 1/32768 the C++ path uses, so an Ogg and its WAV twin transcribe identically.
        let scale = Float(1.0 / 32768.0)

        let channels = (0..<stride).map { channel -> [Float] in
            var values = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                values[frame] = Float(samples[frame * stride + channel]) * scale
            }
            return values
        }

        return Decoded(channels: channels, sampleRate: Double(sampleRate))
    }
}
