import Foundation

/// Test-only URLProtocol that intercepts every request through a `URLSession`
/// configured with `protocolClasses = [MockURLProtocol.self]`. The handler is a
/// per-process function set by the active test — keep tests serialized when
/// concurrent setters would race.
///
/// The handler returns either a synthetic response (status, headers, body) or an
/// `Error` to drive transport-failure paths.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// Wrapped in a class so we can mutate it from tests without rebuilding the URLSession.
    private final class HandlerBox: @unchecked Sendable {
        var handler: Handler?
    }
    private static let box = HandlerBox()
    static let lock = NSLock()

    static func setHandler(_ handler: Handler?) {
        lock.lock(); defer { lock.unlock() }
        box.handler = handler
    }

    static func currentHandler() -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return box.handler
    }

    /// Global cross-suite gate. swift-testing's `.serialized` only orders tests
    /// inside one suite; suites still run concurrently. Networking tests share
    /// `MockURLProtocol`'s static handler, so they must serialize *across* suites
    /// or they'll trample each other.
    static let crossSuiteGate = NSLock()

    /// Acquire the gate at the top of each networking test, then `defer` release.
    static func acquireGate() {
        crossSuiteGate.lock()
    }

    static func releaseGate() {
        setHandler(nil)
        crossSuiteGate.unlock()
    }

    /// Make a `URLSession` that uses only `MockURLProtocol`. Every test that mutates
    /// `setHandler` should construct its own session via this helper.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Convenience: build an HTTP response. Body is JSON serialized into UTF-8.
    static func jsonResponse(url: URL, status: Int = 200, json: Any) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    static func textResponse(url: URL, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
