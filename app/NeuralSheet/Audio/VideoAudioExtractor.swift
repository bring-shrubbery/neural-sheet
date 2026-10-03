import AVFoundation
import Foundation

/// Pulls the first audio track out of a video into a file of its own, which is then the take
/// (input formats design §2, §3).
///
/// The take is the audio file, never the video: Save copies `SourceAudio.sourcePath` into the
/// package, and a package should not carry a gigabyte of picture nobody can see. The file is
/// written into `AppPaths.recordings`, whose lifecycle already fits -- a save copies it into the
/// package, a close deletes it, and a crash's leftover is swept at launch.
///
/// Lossless either way: AAC and Apple Lossless are copied as they are into an `.m4a`; anything
/// else (the LPCM of a QuickTime screen recording, say) is decoded to float and written as a
/// `.caf`, which holds every integer PCM format without rounding.
///
/// Slow and blocking in places (`AVAssetReader` reads synchronously), so callers run it off the
/// main actor. Cancellation is honoured between buffers and by the export itself, and a cancelled
/// or failed extraction leaves no file behind.
nonisolated enum VideoAudioExtractor {
    /// The track formats copied without re-encoding: every AAC flavour an `.m4a` can hold, and ALAC.
    private static let passthroughFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
        kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatAppleLossless,
    ]

    /// Writes the first audio track of `video` into `directory` and returns the new file, named
    /// after the video. Passthrough `.m4a` for AAC / ALAC, decoded PCM `.caf` for anything else.
    ///
    /// - Throws: `CancellationError` when the task was cancelled, otherwise
    ///   `AudioFileLoader.LoadError.decodeFailed` for an unreadable asset, a video with no audio
    ///   track, or a failed write -- the caller shows one message for all of them.
    static func extract(video: URL, into directory: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let formats = try? await track.load(.formatDescriptions)
        else { throw AudioFileLoader.LoadError.decodeFailed }

        let passthrough = formats.first.map { passthroughFormats.contains(CMFormatDescriptionGetMediaSubType($0)) }
            ?? false

        let manager = FileManager.default
        let destination = directory
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(passthrough ? "m4a" : "caf")

        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Two drops of the same clip: the second replaces the first's file.
            try? manager.removeItem(at: destination)

            if passthrough {
                try await copyTrack(track, of: asset, to: destination)
            } else {
                try decodeTrack(track, of: asset, to: destination)
            }

            try Task.checkCancellation()
        } catch {
            try? manager.removeItem(at: destination)

            if error is CancellationError || Task.isCancelled { throw CancellationError() }

            throw AudioFileLoader.LoadError.decodeFailed
        }

        return destination
    }

    // MARK: - Passthrough

    /// The track as it is, into an `.m4a`. The export reads a composition holding the audio track
    /// alone: an `.m4a` cannot carry the video, and a passthrough export of the whole asset would
    /// refuse rather than drop it.
    private static func copyTrack(_ track: AVAssetTrack, of asset: AVAsset, to destination: URL) async throws {
        let composition = AVMutableComposition()

        guard let audio = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioFileLoader.LoadError.decodeFailed }

        let range = try await track.load(.timeRange)
        try audio.insertTimeRange(range, of: track, at: .zero)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw AudioFileLoader.LoadError.decodeFailed }

        try await session.export(to: destination, as: .m4a)
    }

    // MARK: - Decode

    /// Any other codec, decoded to interleaved float at the track's own rate and channel count and
    /// written as it comes, a buffer at a time, so a long take is never held whole twice.
    private static func decodeTrack(_ track: AVAssetTrack, of asset: AVAsset, to destination: URL) throws {
        let reader = try AVAssetReader(asset: asset)

        // No rate or channel keys: the reader keeps the track's own, and the first buffer says
        // what they are.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { throw AudioFileLoader.LoadError.decodeFailed }

        reader.add(output)

        guard reader.startReading() else { throw AudioFileLoader.LoadError.decodeFailed }

        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var file: AVAudioFile?

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let description = CMSampleBufferGetFormatDescription(sample),
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                           channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                           interleaved: true)
            else { throw AudioFileLoader.LoadError.decodeFailed }

            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))

            guard frames > 0 else { continue }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw AudioFileLoader.LoadError.decodeFailed
            }

            buffer.frameLength = frames

            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)

            guard status == noErr else { throw AudioFileLoader.LoadError.decodeFailed }

            if file == nil {
                file = try AVAudioFile(forWriting: destination, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: true)
            }

            try file?.write(from: buffer)
        }

        guard reader.status == .completed, file != nil else { throw AudioFileLoader.LoadError.decodeFailed }
    }
}
