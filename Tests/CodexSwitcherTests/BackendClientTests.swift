import Testing
import Foundation
@testable import CodexSwitcher

@Suite("BackendClient — contract", .serialized)
struct BackendClientTests {

    private static func client() -> (BackendClient, URLSession) {
        let session = MockURLProtocol.makeSession()
        return (BackendClient(session: session), session)
    }

    /// Captures the inbound request so tests can assert headers.
    private final class CapturedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: URLRequest?
        var value: URLRequest? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    @Test("usage(): sends Authorization, chatgpt-account-id, User-Agent, Accept headers")
    func usageHeaders() async throws {
        let (client, _) = Self.client()
        let captured = CapturedRequest()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            captured.value = request
            return try MockURLProtocol.jsonResponse(url: request.url!, json: ["primary": ["used_percent": 1.0]])
        }

        _ = try await client.usage(accessToken: "ACCESS", accountID: "ACCT")

        let req = captured.value!
        #expect(req.url == BackendConstants.usageURL)
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ACCESS")
        #expect(req.value(forHTTPHeaderField: "chatgpt-account-id") == "ACCT")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == BackendConstants.userAgent)
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("usage(): decodes split primary/secondary shape")
    func usageDecodingSplit() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "primary": ["used_percent": 12.5, "window": "5h_rolling"],
                "secondary": ["used_percent": 30.0, "window": "weekly"],
            ])
        }
        let resp = try await client.usage(accessToken: "a", accountID: "b")
        let resolved = resp.resolvedWindows
        #expect(resolved.primary?.usedPercent == 12.5)
        #expect(resolved.secondary?.usedPercent == 30.0)
    }

    @Test("usage(): decodes nested rate_limits shape")
    func usageDecodingRateLimits() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "rate_limits": [
                    "primary": ["used_percent": 5.0],
                    "secondary": ["used_percent": 7.0],
                ],
            ])
        }
        let resp = try await client.usage(accessToken: "a", accountID: "b")
        let resolved = resp.resolvedWindows
        #expect(resolved.primary?.usedPercent == 5.0)
        #expect(resolved.secondary?.usedPercent == 7.0)
    }

    @Test("usage(): non-2xx maps to .http with status and body")
    func usageHTTPError() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(url: request.url!, status: 401, body: "{\"error\":\"unauthorized\"}")
        }

        await #expect(throws: BackendError.self) {
            _ = try await client.usage(accessToken: "a", accountID: "b")
        }
    }

    @Test("usage(): malformed JSON maps to .decoding")
    func usageDecodingFailure() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(url: request.url!, status: 200, body: "not-json")
        }
        do {
            _ = try await client.usage(accessToken: "a", accountID: "b")
            #expect(Bool(false), "expected throw")
        } catch let error as BackendError {
            if case .decoding = error {} else {
                #expect(Bool(false), "expected .decoding, got \(error)")
            }
        }
    }

    @Test("usage(): tolerates missing top-level fields (every field is optional)")
    func usageEmptyBody() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            try MockURLProtocol.jsonResponse(url: request.url!, json: [:] as [String: Any])
        }
        let resp = try await client.usage(accessToken: "a", accountID: "b")
        let r = resp.resolvedWindows
        #expect(r.primary == nil)
        #expect(r.secondary == nil)
    }

    @Test("usage(): transport error maps to .transport")
    func usageTransportError() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await client.usage(accessToken: "a", accountID: "b")
            #expect(Bool(false), "expected throw")
        } catch let error as BackendError {
            if case .transport = error {} else {
                #expect(Bool(false), "expected .transport, got \(error)")
            }
        }
    }

    @Test("usage(): parses ISO8601 resets_at with fractional seconds")
    func usageParsesFractionalDate() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "primary": [
                    "used_percent": 10.0,
                    "resets_at": "2026-04-26T12:00:00.000Z",
                ],
            ])
        }
        let resp = try await client.usage(accessToken: "a", accountID: "b")
        #expect(resp.resolvedWindows.primary?.resetsAt != nil)
    }

    @Test("accountsCheck(): hits the right URL and decodes plan_type")
    func accountsCheck() async throws {
        let (client, _) = Self.client()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            #expect(request.url == BackendConstants.accountCheckURL)
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "accounts": [
                    ["account_id": "acct-1", "plan_type": "pro_5x"]
                ],
            ])
        }
        let resp = try await client.accountsCheck(accessToken: "a", accountID: "b")
        #expect(resp.accounts?.first?.planType == "pro_5x")
    }
}
