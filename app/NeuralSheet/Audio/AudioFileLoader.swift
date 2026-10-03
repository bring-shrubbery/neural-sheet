import AVFoundation
import Foundation
import NeuralSheetCore

/// Turns a file on disk into a ``SourceAudio``.
///
/// Everything AVFoundation can decode goes through `AVAudioFile`; Ogg Vorbis, which it cannot, goes
/// through the vendored stb_vorbis. A video is not read here: ``VideoAudioExtractor`` writes its
/// audio track to a file of its own first, and that file comes through here like any other. Either way the result is float channels at the file's own rate,
/// which are then converted twice: to the device rate for playback and to 16 kHz mono for the model.
nonisolated enum AudioFileLoader {
    /// The extensions the drop target and the file chooser accept, lower-cased, in the order the
    /// original listed them in its "Could not load the file." message: the hard-coded ".mp3",
    /// then each registered JUCE format's own list (`WavAudioFormat` ".wav .bwf", Aiff, Flac, Ogg).
    ///
    /// The AAC, Core Audio and video extensions follow the inventory's list rather than mixing into
    /// it, so the message reads as it did before they were added (input formats design §3).
    static let acceptedExtensions = [
        "mp3", "wav", "bwf", "aiff", "aif", "flac", "ogg",
        "m4a", "aac", "caf", "mp4", "m4v", "mov",
    ]

    /// The subset of ``acceptedExtensions`` whose audio is extracted before it is loaded. An `.mp4`
    /// holding only audio takes that path too: extracting is cheaper than probing for a video
    /// track, and the result is the same file (input formats design §2).
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// ".mp3, .wav, …": the list every "Check your file format" message quotes, built from
    /// ``acceptedExtensions`` so the message cannot fall behind what is accepted.
    static var acceptedFormatsList: String {
        acceptedExtensions.map { ".\($0)" }.joined(separator: ", ")
    }

    nonisolated enum LoadError: Error {
        /// The file is not one of ``acceptedExtensions``.
        case unsupportedExtension
        /// The extension was right but nothing could be read out of the file.
        case decodeFailed
    }

    /// Reads `url` and returns it ready to play at `deviceRate` and ready to transcribe at 16 kHz.
    ///
    /// Slow and allocating: the message thread's, off the main queue for a long file.
    ///
    /// - Parameter namedAfterFile: False for a recording re-read from `AppPaths.recordings`, which
    ///   was never a dropped file and shows no name (``SourceAudio/droppedFileName`` is nil).
    /// - Parameter displayName: The name the take shows when it is named after a file; nil is the
    ///   file's own stem. A video's extracted audio passes the video's name, so the title and the
    ///   export names show what was dropped rather than the copy in the recordings folder.
    static func load(url: URL, deviceRate: Double, namedAfterFile: Bool = true,
                     displayName: String? = nil) throws -> SourceAudio {
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
            droppedFileName: namedAfterFile ? (displayName ?? url.deletingPathExtension().lastPathComponent) : nil,
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

    /// mp3 / wav / bwf / aiff / aif / flac / m4a / aac / caf. `processingFormat` is always deinterleaved float32, so the
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
