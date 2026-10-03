import AVFoundation
import Foundation
import NeuralSheetCore

/// The stems on disk (audio export design §2): the 24-bit `.caf` a kept separation writes beside
/// the recordings, and the 24-bit WAV at the take's rate and channel count Export Stems… makes of
/// each. Any thread but the render thread; nothing here touches the live engine.
nonisolated enum StemFiles {
    enum Failure: Error, LocalizedError {
        case format
        case converter

        var errorDescription: String? {
            switch self {
            case .format: String(localized: "The audio format is not available.", comment: "Alert body: Export Stems… could not set up the format")
            case .converter: String(localized: "The audio could not be converted.", comment: "Alert body: Export Stems… could not convert")
            }
        }
    }

    /// The frames converted at a time.
    private static let chunkFrames: AVAudioFrameCount = 8192

    /// The 24-bit integer settings both files are written with, at `sampleRate`.
    private static func settings(sampleRate: Double, channels: Int, wav: Bool) -> [String: Any] {
        var settings = AudioExportFormat.wav24.fileSettings(sampleRate: sampleRate, channels: channels)
        // A CAF takes the same 24-bit PCM; only the container differs.
        if !wav { settings["AVLinearPCMIsBigEndianKey"] = false }

        return settings
    }

    /// Writes one stem, planar left and right at `sampleRate`, as a 24-bit stereo `.caf`.
    static func writeCAF(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
                         to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings(sampleRate: sampleRate, channels: 2, wav: false),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
              let channels = buffer.floatChannelData
        else { throw Failure.format }

        var position = 0

        while position < frames {
            let count = min(Int(chunkFrames), frames - position)

            channels[0].update(from: left + position, count: count)
            channels[1].update(from: right + position, count: count)
            buffer.frameLength = AVAudioFrameCount(count)

            try file.write(from: buffer)
            position += count
        }
    }

    /// Converts a kept `.caf` to a 24-bit WAV at `sampleRate` with `channels` channels (1 or 2:
    /// a mono take gets the stem folded down), exactly `frameCount` frames long -- the take's own
    /// length, so the four files line up with it and with each other whatever the conversion's
    /// rounding. Streams in chunks; never holds a whole stem.
    static func convert(_ source: URL, to destination: URL, sampleRate: Double, channels: Int,
                        frameCount: Int) throws {
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat
        let outChannels = min(max(channels, 1), 2)

        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                            channels: AVAudioChannelCount(outChannels))
        else { throw Failure.format }

        let output = try AVAudioFile(forWriting: destination,
                                     settings: settings(sampleRate: sampleRate, channels: outChannels, wav: true),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw Failure.converter }

        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outCapacity = AVAudioFrameCount((Double(chunkFrames) * sampleRate / inFormat.sampleRate).rounded(.up)) + 256

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
        else { throw Failure.format }

        let feed = ConverterFeed(file: input, buffer: inBuffer, chunk: chunkFrames)
        var written = 0

        while written < frameCount {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                feed.next(outStatus)
            }

            if status == .error { throw error ?? Failure.converter }
            if let readError = feed.error { throw readError }

            let frames = min(Int(outBuffer.frameLength), frameCount - written)

            if frames > 0 {
                outBuffer.frameLength = AVAudioFrameCount(frames)
                try output.write(from: outBuffer)
                written += frames
            }

            if status == .endOfStream || (status == .inputRanDry && outBuffer.frameLength == 0) { break }
        }

        // Short by the converter's rounding: silence to the take's length.
        if written < frameCount {
            try writeSilence(frameCount - written, format: outFormat, to: output)
        }
    }

    private static func writeSilence(_ frames: Int, format: AVAudioFormat, to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { throw Failure.format }

        var remaining = frames

        while remaining > 0 {
            let count = min(Int(chunkFrames), remaining)
            buffer.frameLength = AVAudioFrameCount(count)

            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].update(repeating: 0, count: count)
                }
            }

            try file.write(from: buffer)
            remaining -= count
        }
    }
}

/// The converter's input: the next chunk of the file, or the end of it. A class so the input
/// block, which the converter may call several times per output buffer, keeps its place.
private nonisolated final class ConverterFeed: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let chunk: AVAudioFrameCount
    var ended = false
    var error: Error?

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer, chunk: AVAudioFrameCount) {
        self.file = file
        self.buffer = buffer
        self.chunk = chunk
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        // Reading at the end throws (`eofErr`) rather than returning nothing.
        if file.framePosition >= file.length { ended = true }

        guard !ended else {
            status.pointee = .endOfStream
            return nil
        }

        do {
            try file.read(into: buffer, frameCount: chunk)
        } catch {
            self.error = error
            ended = true
        }

        guard !ended, buffer.frameLength > 0 else {
            ended = true
            status.pointee = .endOfStream
            return nil
        }

        status.pointee = .haveData
        return buffer
    }
}
