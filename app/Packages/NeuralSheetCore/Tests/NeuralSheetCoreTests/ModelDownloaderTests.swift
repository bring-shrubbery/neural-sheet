import CryptoKit
import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Harness

/// Thread-safe storage, for values written from delegate queues and read from the test.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    var get: T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private struct Context {
    let paths: AppPaths
    let spec: ModelSpec
    let stubPath: String
    let body: Data
    let downloader: ModelDownloader

    var partURL: URL { paths.models.appendingPathComponent(spec.partFileName) }
    var installedURL: URL { paths.models.appendingPathComponent(spec.fileName) }
}

private func hexDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
}

/// Builds a downloader over a 1 KiB fake model served by `StubURLProtocol`, in a temp directory.
private func withDownloader(
    retryDelays: [TimeInterval] = [], _ body: (Context) throws -> Void
) throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("neuralsheet-download-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let paths = AppPaths(
        root: base.appendingPathComponent("NeuralSheet", isDirectory: true),
        secondaryModels: base.appendingPathComponent("NeuralNote/models", isDirectory: true),
        music: base.appendingPathComponent("Music", isDirectory: true))
    try paths.ensureDirectories()

    let payload = Data((0..<1024).map { UInt8($0 % 251) })
    let digest = hexDigest(payload)
    let stubPath = "/v1/fake-\(UUID().uuidString).gguf"
    defer { StubURLProtocol.unregister(path: stubPath) }

    let specs = ModelSize.allCases.map { size in
        ModelSpec(
            size: size, fileName: "fake-\(size.rawValue).gguf", byteSize: Int64(payload.count),
            sha256Hex: digest, url: URL(string: "https://stub.invalid\(stubPath)")!)
    }

    let session = StubURLProtocol.makeSession()
    defer { session.invalidateAndCancel() }

    let downloader = ModelDownloader(
        specs: specs, paths: paths, session: session, retryDelays: retryDelays)

    try body(
        Context(
            paths: paths, spec: specs[1], stubPath: stubPath, body: payload, downloader: downloader))
}

/// Starts `size` and returns the phase it settles in.
private func runToCompletion(
    _ context: Context, _ size: ModelSize = .medium, timeout: TimeInterval = 20
) -> DownloadPhase {
    let finished = DispatchSemaphore(value: 0)
    let last = Box<DownloadPhase>(.idle)

    context.downloader.onChange = { changed, phase in
        guard changed == size else { return }
        switch phase {
        case .idle, .failed:
            last.set(phase)
            finished.signal()
        case .downloading, .verifying:
            break
        }
    }

    context.downloader.start(size)
    #expect(finished.wait(timeout: .now() + timeout) == .success)
    return last.get
}

private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(2000)
    }
    return condition()
}

private func failureMessage(_ phase: DownloadPhase) -> String? {
    if case .failed(let message) = phase { return message }
    return nil
}

// MARK: - Tests

/// Serialised: every test here blocks its thread while a request is in flight, and a dozen at once
/// starve the pool the responses are delivered on.
@Suite(.serialized) struct ModelDownloadTests {
    @Test func fullDownloadVerifiesAndInstalls() throws {
        try withDownloader { context in
            let seenRange = Box<String?>(nil)
            StubURLProtocol.register(path: context.stubPath) { request in
                seenRange.set(request.value(forHTTPHeaderField: "Range"))
                return StubResponse(statusCode: 200, chunks: [context.body])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            #expect(seenRange.get == nil)
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
            #expect(!FileManager.default.fileExists(atPath: context.partURL.path))
            #expect(ModelStore(paths: context.paths, specs: [context.spec]).installed() == [.medium])
        }
    }

    @Test func partialContentResumesFromThePartFile() throws {
        try withDownloader { context in
            try context.body.prefix(512).write(to: context.partURL)

            let seenRange = Box<String?>(nil)
            StubURLProtocol.register(path: context.stubPath) { request in
                seenRange.set(request.value(forHTTPHeaderField: "Range"))
                return StubResponse(
                    statusCode: 206, headers: ["Content-Range": "bytes 512-1023/1024"],
                    chunks: [context.body.suffix(from: 512)])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            #expect(seenRange.get == "bytes=512-")
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
            #expect(!FileManager.default.fileExists(atPath: context.partURL.path))
        }
    }

    @Test func anUnexpectedContentRangeStartsOver() throws {
        try withDownloader { context in
            try context.body.prefix(512).write(to: context.partURL)

            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(
                    statusCode: 206, headers: ["Content-Range": "bytes 0-1023/1024"], chunks: [context.body])
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "Unexpected response from huggingface.co")
            #expect(!FileManager.default.fileExists(atPath: context.partURL.path))
        }
    }

    @Test func anOkAnswerToARangeRequestStartsOver() throws {
        try withDownloader { context in
            try Data(repeating: 9, count: 512).write(to: context.partURL)

            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(statusCode: 200, chunks: [context.body])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
        }
    }

    @Test func rangeNotSatisfiableDeletesThePartAndFails() throws {
        try withDownloader { context in
            try Data(repeating: 7, count: 512).write(to: context.partURL)

            StubURLProtocol.register(path: context.stubPath) { _ in StubResponse(statusCode: 416) }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "The partial download could not be resumed")
            #expect(!FileManager.default.fileExists(atPath: context.partURL.path))
            #expect(!FileManager.default.fileExists(atPath: context.installedURL.path))
        }
    }

    @Test func aCorruptedDownloadIsDeletedAndReported() throws {
        try withDownloader { context in
            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(statusCode: 200, chunks: [Data(repeating: 0xAB, count: 1024)])
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "The download was corrupted. Try again")
            #expect(!FileManager.default.fileExists(atPath: context.partURL.path))
            #expect(!FileManager.default.fileExists(atPath: context.installedURL.path))
        }
    }

    @Test func anOverLongBodyIsRejected() throws {
        try withDownloader(retryDelays: [0, 0, 0]) { context in
            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(statusCode: 200, chunks: [context.body, context.body])
            }

            let phase = runToCompletion(context)

            // Non-retryable, so the injected delays are never used.
            #expect(failureMessage(phase) == "huggingface.co sent more than the expected size")
            #expect(!FileManager.default.fileExists(atPath: context.installedURL.path))
        }
    }

    @Test func aShortBodyReportsTheConnectionDropped() throws {
        try withDownloader { context in
            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(statusCode: 200, chunks: [context.body.prefix(512)])
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "The connection dropped")
            // What arrived is kept, so the next attempt resumes.
            #expect(fileSize(context.partURL) == 512)
        }
    }

    @Test func anUnexpectedStatusCodeIsReported() throws {
        try withDownloader(retryDelays: [0, 0, 0]) { context in
            let requests = Box(0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                requests.set(requests.get + 1)
                return StubResponse(statusCode: 404)
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "huggingface.co answered HTTP 404")
            // 404 is not retryable, whatever the delays say.
            #expect(requests.get == 1)
        }
    }

    @Test func serverErrorsAreRetried() throws {
        try withDownloader(retryDelays: [0, 0, 0]) { context in
            let requests = Box(0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                requests.set(requests.get + 1)
                if requests.get < 3 { return StubResponse(statusCode: 503) }
                return StubResponse(statusCode: 200, chunks: [context.body])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            #expect(requests.get == 3)
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
        }
    }

    @Test func serverErrorsGiveUpAfterTheLastDelay() throws {
        try withDownloader(retryDelays: [0, 0]) { context in
            let requests = Box(0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                requests.set(requests.get + 1)
                return StubResponse(statusCode: 503)
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "huggingface.co answered HTTP 503")
            // One attempt per injected delay, plus the first.
            #expect(requests.get == 3)
        }
    }

    @Test func aConnectFailureIsReported() throws {
        try withDownloader { context in
            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(error: URLError(.cannotConnectToHost))
            }

            let phase = runToCompletion(context)

            #expect(failureMessage(phase) == "Could not reach huggingface.co")
        }
    }

    @Test func cancelKeepsThePartFile() throws {
        try withDownloader { context in
            let resume = DispatchSemaphore(value: 0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(
                    statusCode: 200,
                    chunks: [context.body.prefix(512), context.body.suffix(from: 512)],
                    pauseAfterFirstChunk: resume)
            }

            let finished = DispatchSemaphore(value: 0)
            let last = Box<DownloadPhase>(.idle)
            context.downloader.onChange = { _, phase in
                switch phase {
                case .idle, .failed:
                    last.set(phase)
                    finished.signal()
                case .downloading, .verifying:
                    break
                }
            }

            context.downloader.start(.medium)

            #expect(
                waitUntil { context.downloader.phase(of: .medium) == .downloading(received: 512, total: 1024) })

            context.downloader.cancel(.medium)
            resume.signal()

            #expect(finished.wait(timeout: .now() + 20) == .success)
            #expect(last.get == .idle)
            #expect(context.downloader.phase(of: .medium) == .idle)
            #expect(fileSize(context.partURL) == 512)
            #expect(!FileManager.default.fileExists(atPath: context.installedURL.path))
        }
    }

    @Test func startingASizeAlreadyDownloadingIsANoOp() throws {
        try withDownloader { context in
            let resume = DispatchSemaphore(value: 0)
            let requests = Box(0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                requests.set(requests.get + 1)
                return StubResponse(
                    statusCode: 200,
                    chunks: [context.body.prefix(512), context.body.suffix(from: 512)],
                    pauseAfterFirstChunk: resume)
            }

            let finished = DispatchSemaphore(value: 0)
            context.downloader.onChange = { _, phase in
                if phase == .idle || failureMessage(phase) != nil { finished.signal() }
            }

            context.downloader.start(.medium)
            #expect(
                waitUntil { context.downloader.phase(of: .medium) == .downloading(received: 512, total: 1024) })

            context.downloader.start(.medium)
            resume.signal()

            #expect(finished.wait(timeout: .now() + 20) == .success)
            #expect(requests.get == 1)
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
        }
    }

    @Test func aRedirectToTheCdnKeepsTheRangeHeader() throws {
        try withDownloader { context in
            try context.body.prefix(512).write(to: context.partURL)

            let cdnPath = "/cdn\(context.stubPath)"
            defer { StubURLProtocol.unregister(path: cdnPath) }

            StubURLProtocol.register(path: context.stubPath) { _ in
                StubResponse(
                    statusCode: 302, headers: ["Location": "https://cdn.invalid\(cdnPath)"])
            }

            let cdnRange = Box<String?>(nil)
            StubURLProtocol.register(path: cdnPath) { request in
                cdnRange.set(request.value(forHTTPHeaderField: "Range"))
                return StubResponse(
                    statusCode: 206, headers: ["Content-Range": "bytes 512-1023/1024"],
                    chunks: [context.body.suffix(from: 512)])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            #expect(cdnRange.get == "bytes=512-")
            let installed = try Data(contentsOf: context.installedURL)
            #expect(installed == context.body)
        }
    }

    @Test func anInstalledModelIsNotDownloadedAgain() throws {
        try withDownloader { context in
            try context.body.write(to: context.installedURL)

            let requests = Box(0)
            StubURLProtocol.register(path: context.stubPath) { _ in
                requests.set(requests.get + 1)
                return StubResponse(statusCode: 200, chunks: [context.body])
            }

            let phase = runToCompletion(context)

            #expect(phase == .idle)
            #expect(requests.get == 0)
        }
    }
}
