import Foundation
import NeuralSheetCore

/// Separates a take into drums, bass, other and vocals through demucs.cpp (stem separation
/// design §3), on a thread of its own, one run at a time.
///
/// Threading: `run` is any thread's but the render thread's; `onProgress` arrives from the
/// library's worker threads, serialised; `completion` from the run's own thread. A cancelled
/// run finishes in the background and its completion is never delivered. `@unchecked Sendable`
/// with `lock` over the run state.
nonisolated final class StemSeparator: @unchecked Sendable {
    /// The four stems as the transcription model reads them: 16 kHz mono.
    struct Stems: Sendable {
        var drums: [Float]
        var bass: [Float]
        var other: [Float]
        var vocals: [Float]

        /// In the order the library produces them.
        var all: [[Float]] { [drums, bass, other, vocals] }
    }

    enum Failure: Error, Equatable, Sendable {
        /// The weights would not load: missing, or not a Demucs checkpoint.
        case load
        case separate(String)

        var message: String {
            switch self {
            case .load: "the stems model could not be loaded"
            case let .separate(reason): reason
            }
        }
    }

    /// How many stretches the take is cut into, one thread each. Each holds its own working
    /// buffers, so this is not every core.
    static let threads = 4

    private let lock = NSLock()
    private var running = false
    private var abandoned = false
    private var progressHandler: (@Sendable (Float) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts the separation of `source`. Refused, with an assertion in debug, while one runs.
    func run(modelPath: URL,
             source: SourceAudio,
             onProgress: @escaping @Sendable (Float) -> Void,
             completion: @escaping @Sendable (Result<Stems, Failure>) -> Void) {
        lock.lock()
        if running {
            lock.unlock()
            assertionFailure("StemSeparator.run while a run is in flight")
            completion(.failure(.separate("a separation is already running")))
            return
        }
        running = true
        abandoned = false
        progressHandler = onProgress
        lock.unlock()

        let thread = Thread { [self] in
            let result = separate(modelPath: modelPath, source: source)

            lock.lock()
            let deliver = !abandoned
            running = false
            progressHandler = nil
            lock.unlock()

            if deliver {
                completion(result)
            }
        }

        thread.name = "NeuralSheet.StemSeparation"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Abandons the run in flight: its completion is dropped. The library cannot be stopped
    /// mid-way, so the thread runs on until it is done.
    func cancel() {
        lock.lock()
        abandoned = true
        progressHandler = nil
        lock.unlock()
    }

    // MARK: - The separation thread

    private func separate(modelPath: URL, source: SourceAudio) -> Result<Stems, Failure> {
        guard let separator = nsheet_stems_load(modelPath.path) else {
            return .failure(.load)
        }
        defer { nsheet_stems_free(separator) }

        // The take at the model's rate, stereo; a mono take feeds both channels.
        let channels = (0..<source.channelCount).map { channel in
            [Float](UnsafeBufferPointer(start: source.base(ofChannel: channel), count: source.frameCount))
        }
        let resampled = source.deviceRate == Double(NSHEET_STEMS_SAMPLE_RATE)
            ? channels
            : Resampler.resample(channels: channels, from: source.deviceRate, to: Double(NSHEET_STEMS_SAMPLE_RATE))

        guard let left = resampled.first, !left.isEmpty else {
            return .failure(.separate("the take is empty"))
        }

        let right = resampled.count > 1 ? resampled[1] : left
        let frames = min(left.count, right.count)

        var output: UnsafeMutablePointer<Float>?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let trampoline: nsheet_stems_progress_fn = { progress, ctx in
            guard let ctx else { return }

            Unmanaged<StemSeparator>.fromOpaque(ctx).takeUnretainedValue().report(progress)
        }

        let status = left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                nsheet_stems_separate(separator, leftBuffer.baseAddress, rightBuffer.baseAddress, frames,
                                      Int32(StemSeparator.threads), trampoline, context, &output)
            }
        }

        guard status == Int32(NSHEET_STEMS_OK.rawValue), let output else {
            let text = nsheet_stems_describe_error(status).map { String(cString: $0) } ?? "unknown error"
            return .failure(.separate(text))
        }
        defer { nsheet_stems_free_audio(output) }

        // Each stem folded to mono and taken to the transcription model's rate.
        var stems: [[Float]] = []
        for stem in 0..<Int(NSHEET_STEM_COUNT.rawValue) {
            let leftBase = output + (stem * 2) * frames
            let rightBase = output + (stem * 2 + 1) * frames
            var mono = [Float](repeating: 0, count: frames)

            for i in 0..<frames {
                mono[i] = (leftBase[i] + rightBase[i]) * 0.5
            }

            let mono16k = Resampler.resample(channels: [mono], from: Double(NSHEET_STEMS_SAMPLE_RATE), to: 16_000).first ?? []
            stems.append(mono16k)
        }

        return .success(Stems(drums: stems[0], bass: stems[1], other: stems[2], vocals: stems[3]))
    }

    /// From the worker threads, serialised by the bridge.
    private func report(_ progress: Float) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()

        handler?(progress)
    }
}
