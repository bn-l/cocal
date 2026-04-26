import Testing
import Foundation
@testable import CodexSwitcher

@Suite("TokenRefresher.classifyFailure")
struct TokenRefresherClassifyTests {

    @Test("refresh_token_expired → .expired")
    func mapsExpired() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"refresh_token_expired"}"#)
        #expect(reason == .expired)
    }

    @Test("refresh_token_reused → .exhausted (the single-use rotation gotcha)")
    func mapsExhausted() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"refresh_token_reused"}"#)
        #expect(reason == .exhausted)
    }

    @Test("invalid_grant → .revoked when no more specific reason supplied")
    func mapsRevoked() {
        let reason = TokenRefresher.classifyFailure(status: 400, body: #"{"error":"invalid_grant"}"#)
        #expect(reason == .revoked)
    }

    @Test("Unknown 5xx body → .other")
    func mapsOther() {
        let reason = TokenRefresher.classifyFailure(status: 503, body: "service unavailable")
        #expect(reason == .other)
    }

    @Test("Profile warning maps from refresh failure cleanly")
    func warningMapping() {
        #expect(ProfileWarning(refreshFailure: .expired) == .refreshExpired)
        #expect(ProfileWarning(refreshFailure: .exhausted) == .refreshExhausted)
        #expect(ProfileWarning(refreshFailure: .revoked) == .refreshRevoked)
        #expect(ProfileWarning(refreshFailure: .other) == .unknown)
    }
}

@Suite("TokenRefresher — refresh()", .serialized)
struct TokenRefresherNetworkTests {

    private final class CapturedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: URLRequest?
        var value: URLRequest? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    @Test("Posts JSON body with client_id, grant_type=refresh_token, refresh_token, scope")
    func bodyShape() async throws {
        let session = MockURLProtocol.makeSession()
        let captured = CapturedRequest()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            captured.value = request
            return try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "access_token": "a", "refresh_token": "r", "id_token": "i",
                "token_type": "Bearer", "expires_in": 3600, "scope": "openid",
            ])
        }
        let refresher = TokenRefresher(session: session)
        _ = try await refresher.refresh(refreshToken: "RT-IN")

        let req = captured.value!
        #expect(req.url == BackendConstants.tokenRefreshURL)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == BackendConstants.userAgent)

        // URLProtocol receives the body via a stream; assert via httpBodyStream when present.
        let bodyData: Data
        if let stream = req.httpBodyStream {
            stream.open()
            var collected = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 1024)
                if read <= 0 { break }
                collected.append(buf, count: read)
            }
            stream.close()
            bodyData = collected
        } else {
            bodyData = req.httpBody ?? Data()
        }
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(json?["client_id"] == BackendConstants.oauthClientID)
        #expect(json?["grant_type"] == "refresh_token")
        #expect(json?["refresh_token"] == "RT-IN")
        #expect(json?["scope"] == BackendConstants.oauthScopes)
    }

    @Test("200: decodes the rotated TokenResponse and returns the new refresh_token")
    func rotatedRefreshToken() async throws {
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            try MockURLProtocol.jsonResponse(url: request.url!, json: [
                "access_token": "AT-NEW",
                "refresh_token": "RT-NEW",
                "id_token": "ID-NEW",
                "token_type": "Bearer",
                "expires_in": 3600,
                "scope": "openid",
            ])
        }
        let refresher = TokenRefresher(session: session)
        let resp = try await refresher.refresh(refreshToken: "RT-OLD")
        #expect(resp.accessToken == "AT-NEW")
        #expect(resp.refreshToken == "RT-NEW")
        #expect(resp.idToken == "ID-NEW")
    }

    @Test("expired error body throws .refreshFailure(.expired)")
    func expiredMaps() async throws {
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(url: request.url!, status: 400, body: #"{"error":"refresh_token_expired"}"#)
        }
        do {
            _ = try await TokenRefresher(session: session).refresh(refreshToken: "x")
            #expect(Bool(false), "expected throw")
        } catch let BackendError.refreshFailure(reason) {
            #expect(reason == .expired)
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("reused error body throws .refreshFailure(.exhausted)")
    func exhaustedMaps() async throws {
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(url: request.url!, status: 400, body: #"{"error":"refresh_token_reused"}"#)
        }
        do {
            _ = try await TokenRefresher(session: session).refresh(refreshToken: "x")
            #expect(Bool(false), "expected throw")
        } catch let BackendError.refreshFailure(reason) {
            #expect(reason == .exhausted)
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("Transport error maps to .transport")
    func transportFailure() async throws {
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { _ in throw URLError(.timedOut) }
        do {
            _ = try await TokenRefresher(session: session).refresh(refreshToken: "x")
            #expect(Bool(false), "expected throw")
        } catch let BackendError.transport(_) {
            // ok
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("200 with malformed JSON throws .decoding")
    func malformedSuccessBody() async throws {
        let session = MockURLProtocol.makeSession()
        MockURLProtocol.acquireGate(); defer { MockURLProtocol.releaseGate() }
        MockURLProtocol.setHandler { request in
            MockURLProtocol.textResponse(url: request.url!, status: 200, body: "not-json")
        }
        do {
            _ = try await TokenRefresher(session: session).refresh(refreshToken: "x")
            #expect(Bool(false), "expected throw")
        } catch let BackendError.decoding(_) {
            // ok
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }
}
