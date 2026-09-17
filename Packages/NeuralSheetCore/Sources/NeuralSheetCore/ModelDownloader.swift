import CryptoKit
import Foundation

/// Where one model download has got to.
public enum DownloadPhase: Equatable, Sendable {
    case idle
    case downloading(received: Int64, total: Int64)
    case verifying
    case failed(message: String)
}

/// Downloads checkpoints into the models directory, one job per size.
///
/// A download resumes from whatever the last attempt left behind, is verified against the manifest
/// digest before it is installed, and is retried a few times when the failure looks transient.
public final class ModelDownloader: @unchecked Sendable {
    private static let connectionTimeout: TimeInterval = 30

    /// The chunk the digest is computed over.
    private static let hashChunkBytes = 1 << 20

    private let paths: AppPaths
    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let store: ModelStore

    private let lock = NSLock()
    private var phases: [ModelSize: DownloadPhase] = [:]
    private var jobs: [ModelSize: Job] = [:]
    private var changeHandler: ((ModelSize, DownloadPhase) -> Void)?

    /// Called whenever a phase changes, on an arbitrary queue.
    public var onChange: ((ModelSize, DownloadPhase) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return changeHandler
        }
        set {
            lock.lock()
            changeHandler = newValue
            lock.unlock()
        }
    }

    /// - Parameter retryDelays: How long to wait before each attempt that follows a failed one.
    public convenience init(
        paths: AppPaths, session: URLSession = .shared, retryDelays: [TimeInterval] = [2, 5, 10]
    ) {
        self.init(specs: ModelManifest.all, paths: paths, session: session, retryDelays: retryDelays)
    }

    /// - Parameter specs: The checkpoints to download, which tests replace with small stand-ins.
    public init(
        specs: [ModelSpec], paths: AppPaths, session: URLSession, retryDelays: [TimeInterval]
    ) {
        self.paths = paths
        self.session = session
        self.retryDelays = retryDelays
        store = ModelStore(paths: paths, specs: specs)
    }

    /// Starts, or resumes, the download of one size. A size already downloading is left alone.
    public func start(_ size: ModelSize) {
        let job = Job()

        lock.lock()
        guard jobs[size] == nil else {
            lock.unlock()
            return
        }
        jobs[size] = job
        lock.unlock()

        let spec = store.spec(for: size)

        // Before the job starts, so a phase read in between does not see the last run's phase.
        setPhase(
            .downloading(received: fileByteSize(partURL(for: spec)), total: spec.byteSize), for: size)

        // A thread of its own rather than a queue: the job blocks while a request is in flight,
        // and must never hold on to a worker the response needs.
        let thread = Thread { [self] in
            let failure = run(spec: spec, job: job)

            setPhase(failure.map { DownloadPhase.failed(message: $0) } ?? .idle, for: size)

            lock.lock()
            jobs[size] = nil
            lock.unlock()
        }

        thread.name = "NeuralSheet model download (\(size.rawValue))"
        thread.start()
    }

    /// Stops the download, keeping the partial file so a later start resumes from it.
    public func cancel(_ size: ModelSize) {
        lock.lock()
        let job = jobs[size]
        lock.unlock()

        job?.cancel()
    }

    public func phase(of size: ModelSize) -> DownloadPhase {
        lock.lock()
        defer { lock.unlock() }
        return phases[size] ?? .idle
    }

    // MARK: - The job

    /// One download, from wherever the part file ends to the installed checkpoint.
    ///
    /// - Returns: Why it failed, or nil once installed or cancelled.
    private func run(spec: ModelSpec, job: Job) -> String? {
        if store.installedPath(for: spec.size) != nil {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
        } catch {
            return "Could not create \(paths.models.path)"
        }

        let part = partURL(for: spec)
        store.deleteStalePartFiles()

        var failedAttempts = 0

        while fileByteSize(part) != spec.byteSize {
            let sizeBefore = fileByteSize(part)
            let outcome = attempt(spec: spec, part: part, job: job)

            if job.isCancelled {
                return nil
            }

            guard let failure = outcome.failure else {
                continue
            }

            if !outcome.canRetry {
                return failure
            }

            // A long download is not given up on because of a few drops spread across it.
            if fileByteSize(part) > sizeBefore {
                failedAttempts = 0
            }

            if failedAttempts == retryDelays.count {
                return failure
            }

            let delay = retryDelays[failedAttempts]
            failedAttempts += 1

            if delay > 0 {
                _ = job.wakeUp.wait(timeout: .now() + delay)
            }

            if job.isCancelled {
                return nil
            }
        }

        setPhase(.verifying, for: spec.size)

        guard let digest = Self.sha256Hex(of: part) else {
            try? FileManager.default.removeItem(at: part)
            return "The download was corrupted. Try again"
        }

        if job.isCancelled {
            return nil
        }

        if digest != spec.sha256Hex {
            try? FileManager.default.removeItem(at: part)
            return "The download was corrupted. Try again"
        }

        let target = paths.models.appendingPathComponent(spec.fileName)

        do {
            // Replaces a checkpoint of the wrong size, which is what a file from another release is.
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }

            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            return "Could not move the model into \(paths.models.path)"
        }

        return nil
    }

    /// One request, from wherever the part file ends.
    private func attempt(spec: ModelSpec, part: URL, job: Job) -> AttemptOutcome {
        var offset = fileByteSize(part)

        if offset > spec.byteSize {
            try? FileManager.default.removeItem(at: part)
            offset = 0
        }

        setPhase(.downloading(received: offset, total: spec.byteSize), for: spec.size)

        var request = URLRequest(
            url: spec.url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.connectionTimeout)

        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let delegate = AttemptDelegate(
            part: part, expectedTotal: spec.byteSize, requestedOffset: offset,
            progress: { [weak self] received in
                self?.setPhase(
                    .downloading(received: received, total: spec.byteSize), for: spec.size)
            })

        let task = session.dataTask(with: request)
        task.delegate = delegate

        // A cancel that arrived before the task was published cancelled nothing.
        guard job.attach(task) else {
            return AttemptOutcome(failure: nil)
        }

        task.resume()
        let outcome = delegate.waitForCompletion()
        job.detach()

        return outcome
    }

    private func partURL(for spec: ModelSpec) -> URL {
        paths.models.appendingPathComponent(spec.partFileName)
    }

    private func setPhase(_ phase: DownloadPhase, for size: ModelSize) {
        lock.lock()

        guard phases[size] != phase else {
            lock.unlock()
            return
        }

        phases[size] = phase
        let handler = changeHandler
        lock.unlock()

        // Outside the lock: the handler is free to call back in.
        handler?(size, phase)
    }

    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()

        while let chunk = try? handle.read(upToCount: hashChunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// How one request ended. No failure means the part file grew, and may now be complete.
private struct AttemptOutcome {
    var failure: String?
    var canRetry = true
}

/// The cancellable state of one size's download.
private final class Job: @unchecked Sendable {
    /// Wakes a retry delay.
    let wakeUp = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// - Returns: False when the job was already cancelled, so the task must not start.
    func attach(_ task: URLSessionDataTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancelled else { return false }

        self.task = task
        return true
    }

    func detach() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()

        task?.cancel()
        wakeUp.signal()
    }
}

/// Streams one response body into the part file, so a resumed request appends to what is there.
private final class AttemptDelegate: NSObject, URLSessionDataDelegate {
    private let part: URL
    private let expectedTotal: Int64
    private let requestedOffset: Int64
    private let progress: (Int64) -> Void
    private let finished = DispatchSemaphore(value: 0)

    /// HuggingFace answers every file with a redirect to its CDN, which honours the Range header.
    private static let maxRedirects = 5

    private var handle: FileHandle?
    private var written: Int64 = 0
    private var outcome = AttemptOutcome(failure: nil)
    private var sawResponse = false
    private var redirects = 0

    init(part: URL, expectedTotal: Int64, requestedOffset: Int64, progress: @escaping (Int64) -> Void) {
        self.part = part
        self.expectedTotal = expectedTotal
        self.requestedOffset = requestedOffset
        self.progress = progress
    }

    /// Blocks until the request is over. The delegate callbacks are serialised before this returns.
    func waitForCompletion() -> AttemptOutcome {
        finished.wait()
        return outcome
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1

        guard redirects <= Self.maxRedirects else {
            // Answering nil hands the redirect itself back as the response, which then fails.
            completionHandler(nil)
            return
        }

        var followed = request

        // The CDN is another host, and the range must survive the hop to it.
        if followed.value(forHTTPHeaderField: "Range") == nil,
            let range = task.originalRequest?.value(forHTTPHeaderField: "Range")
        {
            followed.setValue(range, forHTTPHeaderField: "Range")
        }

        completionHandler(followed)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        sawResponse = true

        guard let http = response as? HTTPURLResponse else {
            fail("Unexpected response from \(ModelManifest.host)")
            completionHandler(.cancel)
            return
        }

        var offset = requestedOffset

        switch http.statusCode {
        case 206:
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""

            // "bytes <first>-<last>/<total>", and it must continue the part file.
            let total = contentRange.split(separator: "/").last.flatMap {
                Int64($0.trimmingCharacters(in: .whitespaces))
            }

            guard contentRange.hasPrefix("bytes \(requestedOffset)-"), total == expectedTotal else {
                // Not a continuation of the part file: start again, as for 416.
                deletePart()
                fail("Unexpected response from \(ModelManifest.host)")
                completionHandler(.cancel)
                return
            }

        case 200:
            // The whole file, whether or not a range was asked for.
            if requestedOffset > 0, !deletePart() {
                fail("Could not write to \(part.path)", canRetry: false)
                completionHandler(.cancel)
                return
            }

            offset = 0

        case 416:
            // The part file is not a prefix the server recognises: start again.
            deletePart()
            fail("The partial download could not be resumed")
            completionHandler(.cancel)
            return

        default:
            fail(
                "\(ModelManifest.host) answered HTTP \(http.statusCode)",
                canRetry: http.statusCode >= 500)
            completionHandler(.cancel)
            return
        }

        guard let opened = openPart(at: offset) else {
            fail("Could not write to \(part.path)", canRetry: false)
            completionHandler(.cancel)
            return
        }

        handle = opened
        written = offset
        progress(offset)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard outcome.failure == nil, let handle else { return }

        if written + Int64(data.count) > expectedTotal {
            fail("\(ModelManifest.host) sent more than the expected size", canRetry: false)
            dataTask.cancel()
            return
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            fail("Could not write to \(part.path)", canRetry: false)
            dataTask.cancel()
            return
        }

        written += Int64(data.count)
        progress(written)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let handle {
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                fail("Could not write to \(part.path)", canRetry: false)
            }

            self.handle = nil
        }

        if outcome.failure == nil {
            if let error {
                // A cancel is the job's own doing; the job checks that itself.
                if (error as? URLError)?.code != .cancelled {
                    // Nothing was answered, so the request never got off the ground.
                    fail(
                        sawResponse
                            ? "The connection dropped" : "Could not reach \(ModelManifest.host)")
                }
            } else if written != expectedTotal {
                // A connection that drops mid-body ends the body early rather than reporting.
                fail("The connection dropped")
            }
        }

        finished.signal()
    }

    private func fail(_ message: String, canRetry: Bool = true) {
        guard outcome.failure == nil else { return }
        outcome = AttemptOutcome(failure: message, canRetry: canRetry)
    }

    @discardableResult
    private func deletePart() -> Bool {
        guard FileManager.default.fileExists(atPath: part.path) else { return true }
        return (try? FileManager.default.removeItem(at: part)) != nil
    }

    /// Opens the part file for writing at `offset`, dropping anything past it.
    private func openPart(at offset: Int64) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { return nil }
        }

        guard let handle = try? FileHandle(forWritingTo: part) else { return nil }

        do {
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            try? handle.close()
            return nil
        }

        return handle
    }
}
