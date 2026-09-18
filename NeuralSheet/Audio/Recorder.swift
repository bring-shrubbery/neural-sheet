import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization

/// Records the audio input to the two files the rest of the app reads back.
///
/// A take goes to disk twice at once: `recorded_audio<timestamp>.wav` at the input device's own rate
/// and channel count, and `recorded_audio<timestamp>_downsampled.wav` at the 16 kHz mono the
/// transcription model wants. Both are 16-bit, and both are read back on ``stop()`` -- what plays and
/// what is transcribed is the audio that made the round trip, not the floats that went in, so a
/// re-opened session sounds exactly like the take did.
///
/// The input tap is not the render thread, but it is still a CoreAudio thread: it copies the block
/// and hands it to ``queue``, where the two file writes, the resampler and the peaks all happen.
///
/// `@unchecked Sendable`: ``isRecording`` and the sample counts are atomics, ``livePeaks`` locks
/// itself, and every other stored property belongs to a single context -- the file handles and the
/// resampler to ``queue``, the URLs and the error to whoever drives start/stop (the main thread).
nonisolated final class Recorder: @unchecked Sendable {
    nonisolated enum RecordError: Error {
        /// The recordings directory or one of the two WAVs could not be created.
        case fileCreation
        /// The take was written but could not be read back, so there is nothing to play.
        case readBack
        /// The user has refused microphone access, or never answered.
        case permissionDenied
    }

    /// The prefix every recording's name carries. Only files that have it are ever deleted.
    static let filenamePrefix = "recorded_audio"

    /// The rate the model reads, and the second file's rate.
    private static let transcriptionRate: Double = 16000

    /// How long ``start()`` waits for the answer to a first-run microphone prompt.
    private static let permissionTimeout: Double = 120

    private let engine: PlaybackEngine
    private let paths: AppPaths

    /// Peaks over the downsampled stream as it is written, which is what the waveform draws while a
    /// take is in progress. ``stop()`` replaces them with peaks over the file that came back.
    let livePeaks = WaveformPeaks()

    private(set) var nativeFileURL: URL?
    private(set) var downsampledFileURL: URL?

    /// Why the last ``stop()`` returned nil, when it was a failure rather than an empty take.
    ///
    /// ``stop()`` cannot throw -- it has a take to hand back -- so the error it would have thrown is
    /// left here for the UI to turn into a message box.
    private(set) var lastError: RecordError?

    /// Written on the main thread, read by the tap: the only reason it is an atomic.
    private let recording = Atomic<Bool>(false)

    /// Frames written to each file so far. ``queue`` writes them, the main thread reads them.
    private let nativeFrames = Atomic<Int>(0)
    private let downsampledFrames = Atomic<Int>(0)

    // MARK: - queue's own

    /// Where the writing happens. Serial, so the two files and the resampler need no locking.
    private let queue = DispatchQueue(label: "NeuralSheet.Recorder")

    private var nativeFile: AVAudioFile?
    private var downsampledFile: AVAudioFile?

    /// One instance for the whole take: its filter memory and fractional read position carry between
    /// blocks, so a take recorded in 1024-frame pieces downsamples exactly as one pass would.
    private var resampler: Resampler?

    /// Set once a write has failed. The rest of the take is dropped rather than interleaved into a
    /// file that is already wrong, and what was written before it still reads back.
    private var writeFailed = false

    init(engine: PlaybackEngine, paths: AppPaths) {
        self.engine = engine
        self.paths = paths
    }

    var isRecording: Bool { recording.load(ordering: .relaxed) }

    /// Seconds captured, measured on the downsampled stream so it does not move with the device.
    var durationSeconds: Double {
        Double(downsampledFrames.load(ordering: .relaxed)) / Self.transcriptionRate
    }

    // MARK: - Transport

    /// Opens both files and starts capturing.
    ///
    /// Blocks on the microphone prompt the first time it is called, which is why it is a button's
    /// job and not a view's: the take starts the moment it returns.
    func start() throws {
        guard !isRecording else { return }

        lastError = nil

        try requestMicrophoneAccess()

        do {
            try paths.ensureDirectories()
        } catch {
            throw RecordError.fileCreation
        }

        // The tap goes on before the format is read: installing it is what points the input unit at
        // the chosen device, and until then the node still reports the format of the last one.
        engine.inputTap = { [weak self] buffer, _ in
            self?.receive(buffer)
        }

        let format = engine.inputFormat
        let channelCount = Swift.min(Int(format.channelCount), 2)

        guard format.sampleRate > 0, channelCount > 0 else {
            engine.inputTap = nil
            throw RecordError.fileCreation
        }

        let urls = Self.fileURLs(in: paths.recordings, timestamp: Self.timestamp())

        do {
            let native = try AVAudioFile(
                forWriting: urls.native,
                settings: Self.settings(rate: format.sampleRate, channels: channelCount),
                commonFormat: .pcmFormatFloat32,
                interleaved: false)

            let downsampled: AVAudioFile

            do {
                downsampled = try AVAudioFile(
                    forWriting: urls.downsampled,
                    settings: Self.settings(rate: Self.transcriptionRate, channels: 1),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false)
            } catch {
                // The first file is already on disk and nothing will ever be written to it.
                try? FileManager.default.removeItem(at: urls.native)
                throw error
            }

            queue.sync {
                nativeFile = native
                downsampledFile = downsampled
                resampler = Resampler(
                    sourceRate: format.sampleRate, targetRate: Self.transcriptionRate)
                writeFailed = false
            }
        } catch {
            engine.inputTap = nil
            throw RecordError.fileCreation
        }

        nativeFileURL = urls.native
        downsampledFileURL = urls.downsampled
        nativeFrames.store(0, ordering: .relaxed)
        downsampledFrames.store(0, ordering: .relaxed)
        livePeaks.clear()

        recording.store(true, ordering: .relaxed)
    }

    /// Stops capturing, flushes both files and reads them back as the take to play.
    ///
    /// Returns nil when nothing was captured -- both files are deleted in that case -- and when the
    /// read-back failed, which leaves ``lastError`` set.
    func stop() -> SourceAudio? {
        guard isRecording else { return nil }

        // Before the tap comes off, so a callback already inside `receive` drops its block rather
        // than enqueueing it behind the barrier below.
        recording.store(false, ordering: .relaxed)
        engine.inputTap = nil

        // Drains everything the tap handed over and closes both files, so what is read back below is
        // the whole take and not most of it.
        queue.sync {
            nativeFile = nil
            downsampledFile = nil
            resampler = nil
        }

        guard let native = nativeFileURL, let downsampled = downsampledFileURL else { return nil }

        // Record then stop before a block arrived: two empty WAVs and nothing to play.
        guard nativeFrames.load(ordering: .relaxed) > 0,
            downsampledFrames.load(ordering: .relaxed) > 0
        else {
            discard()
            return nil
        }

        guard let decoded = try? AudioFileLoader.decode(url: native),
            let down = try? AudioFileLoader.decode(url: downsampled),
            !decoded.channels.isEmpty, decoded.sampleRate > 0,
            let mono16k = down.channels.first, !mono16k.isEmpty
        else {
            lastError = .readBack
            return nil
        }

        let deviceRate = engine.sampleRate
        let playback =
            decoded.sampleRate == deviceRate
            ? decoded.channels
            : Resampler.resample(channels: decoded.channels, from: decoded.sampleRate, to: deviceRate)

        // Rebuilt rather than kept: the live peaks came off the floats on their way to disk, and
        // what comes back is 16-bit, so the two are no longer quite the same audio.
        let peaks = WaveformPeaks()
        peaks.build(from: mono16k)

        return SourceAudio(
            deviceRate: deviceRate,
            channels: playback,
            mono16k: mono16k,
            peaks: peaks,
            droppedFileName: nil,
            sourcePath: native
        )
    }

    /// Throws away an empty take: two files that would otherwise sit in the recordings directory
    /// forever, since nothing else knows they exist.
    private func discard() {
        if let nativeFileURL { try? FileManager.default.removeItem(at: nativeFileURL) }
        if let downsampledFileURL { try? FileManager.default.removeItem(at: downsampledFileURL) }

        nativeFileURL = nil
        downsampledFileURL = nil
        livePeaks.clear()
    }

    // MARK: - Capture

    /// The input tap. A CoreAudio thread, but not the render thread -- it still does no more than
    /// copy the block out of the buffer, which AVAudioEngine reuses the moment this returns.
    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard recording.load(ordering: .relaxed), let data = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }

        // `stride` is 1 for the deinterleaved float the engine's nodes deal in, and the channel
        // count for an interleaved format, where every channel lives in the one buffer.
        let stride = buffer.stride

        let channels = (0..<count).map { channel -> [Float] in
            guard stride > 1 else {
                return [Float](UnsafeBufferPointer(start: data[channel], count: frames))
            }

            var samples = [Float](repeating: 0, count: frames)
            let base = data[0] + channel
            for frame in 0..<frames {
                samples[frame] = base[frame * stride]
            }
            return samples
        }

        queue.async { [weak self] in
            self?.write(channels)
        }
    }

    /// One block, on ``queue``: to the native file as it came in, and averaged down to 16 kHz mono
    /// for the second file and the peaks.
    private func write(_ channels: [[Float]]) {
        guard !writeFailed, let nativeFile, let downsampledFile, resampler != nil else { return }

        // The same channels feed both files, so the take that plays and the take that is
        // transcribed are the same audio: a device with more than two inputs loses the rest.
        let captured = Array(channels.prefix(Int(nativeFile.processingFormat.channelCount)))

        guard let buffer = Self.buffer(channels: captured, format: nativeFile.processingFormat) else {
            return
        }

        do {
            try nativeFile.write(from: buffer)
        } catch {
            writeFailed = true
            return
        }

        nativeFrames.add(Int(buffer.frameLength), ordering: .relaxed)

        guard let downsampled = resampler?.process(channels: captured), !downsampled.isEmpty,
            let downBuffer = Self.buffer(
                channels: [downsampled], format: downsampledFile.processingFormat)
        else { return }

        do {
            try downsampledFile.write(from: downBuffer)
        } catch {
            writeFailed = true
            return
        }

        downsampledFrames.add(downsampled.count, ordering: .relaxed)
        livePeaks.append(downsampled)
    }

    // MARK: - Files

    /// A 16-bit little-endian PCM WAV, which the extension picks out of the settings.
    ///
    /// The file is written through a float `processingFormat`: `AVAudioFile` converts on the way in,
    /// so nothing here has to think about integer scaling or clipping.
    private static func settings(rate: Double, channels: Int) -> [String: Any] {
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
    private static func buffer(channels: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
        // write whatever was in that memory into the file.
        for index in channels.count..<Int(format.channelCount) {
            data[index].update(repeating: 0, count: frames)
        }

        return buffer
    }

    /// `YYYY-MM-DD_HH-MM-SS`, in the user's own time zone: these names are read by people.
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// The pair of names for a new take, with `_1`, `_2`… until neither exists.
    ///
    /// The suffix moves both names together, so a take's two files always match -- a second take
    /// inside the same second cannot end up sharing one of them.
    private static func fileURLs(in directory: URL, timestamp: String)
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

    // MARK: - Permission

    /// Microphone access, waited for rather than asked in the background.
    ///
    /// The first call puts up the system prompt and blocks until it is answered, which is a stall on
    /// whatever thread pressed Record; every call after it is a property read. The status is
    /// re-read rather than taken from the callback, so a prompt that times out reads as a refusal.
    private func requestMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return

        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + Self.permissionTimeout)

            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw RecordError.permissionDenied
            }

        default:
            throw RecordError.permissionDenied
        }
    }
}
