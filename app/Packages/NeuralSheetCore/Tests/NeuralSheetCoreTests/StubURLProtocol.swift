import Foundation

/// A canned HTTP answer for one request.
struct StubResponse {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    /// Body pieces, delivered in order.
    var chunks: [Data] = []
    /// When set, the request fails with this error instead of answering.
    var error: Error?
    /// When set, the stub waits on it after the first chunk, so a test can cancel mid-body.
    var pauseAfterFirstChunk: DispatchSemaphore?
}

/// A `URLProtocol` that answers from per-path handlers, so tests never touch the network.
///
/// Routes are keyed by URL path, which lets tests registered under distinct paths run in parallel.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (URLRequest) -> StubResponse] = [:]

    /// A session whose only transport is this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    static func register(path: String, handler: @escaping (URLRequest) -> StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = handler
    }

    static func unregister(path: String) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = nil
    }

    private static func handler(for path: String) -> ((URLRequest) -> StubResponse)? {
        lock.lock()
        defer { lock.unlock() }
        return routes[path]
    }

    private let stopped = NSLock()
    private var isStopped = false

    private func markStopped() {
        stopped.lock()
        isStopped = true
        stopped.unlock()
    }

    private var stoppedNow: Bool {
        stopped.lock()
        defer { stopped.unlock() }
        return isStopped
    }

    // Always true: a request this session sends must never escape to the network.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        // Off the loading thread, so `stopLoading` is never blocked by a paused body.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            guard let path = request.url?.path, let handler = StubURLProtocol.handler(for: path) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }

            let stub = handler(request)

            if let error = stub.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }

            guard
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: stub.statusCode, httpVersion: "HTTP/1.1",
                    headerFields: stub.headers)
            else { return }

            // A custom protocol drives its own redirects; the session then asks its delegate.
            if (300..<400).contains(stub.statusCode),
                let location = stub.headers["Location"], let target = URL(string: location)
            {
                // Deliberately bare, so a header that must survive the hop has to be put back.
                self.client?.urlProtocol(
                    self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            }

            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            for (index, chunk) in stub.chunks.enumerated() {
                if self.stoppedNow { return }
                self.client?.urlProtocol(self, didLoad: chunk)

                if index == 0, let pause = stub.pauseAfterFirstChunk {
                    _ = pause.wait(timeout: .now() + 10)
                    if self.stoppedNow { return }
                }
            }

            if self.stoppedNow { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        markStopped()
    }
}
