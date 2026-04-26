import Testing
import Foundation
@testable import CodexSwitcher

/// Recording warmer that captures every `warm` call.
actor RecordingWarmer: WarmingService {
    var warmedProfileIDs: [String] = []
    func warm(profile: Profile, actor perProfile: PerProfile) async -> Profile {
        warmedProfileIDs.append(profile.id)
        var updated = profile
        updated.lastWarmed = Date()
        return updated
    }
}

@Suite("UsageMonitor — runWarmerIfDue cadence", .serialized)
@MainActor
struct UsageMonitorWarmerTests {

    private static func tempEnvironment() throws -> (AppEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-monitor-warmer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let homeDir = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let env = AppEnvironment(
            profileStore: ProfileStore(rootDirectory: root.appendingPathComponent("profiles")),
            slotStore: SlotStore(url: root.appendingPathComponent("active-slot.json")),
            backend: BackendClient(),
            refresher: TokenRefresher(),
            resolver: AuthPathResolver(environment: [:], homeDirectory: homeDir)
        )
        return (env, root)
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeAuth(user: String, account: String) throws -> AuthJSON {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_user_id": user,
                "chatgpt_account_id": account,
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = #"{"alg":"none"}"#.data(using: .utf8)!
        let token = "\(b64url(header)).\(b64url(payloadData)).sig"
        return AuthJSON(tokens: AuthTokens(idToken: token, accessToken: token, refreshToken: "rt", accountID: account))
    }

    @discardableResult
    private static func insertProfile(_ env: AppEnvironment, label: String, user: String, account: String, lastWarmed: Date? = nil) throws -> Profile {
        let auth = try makeAuth(user: user, account: account)
        let p = Profile(label: label, dedupKey: "\(user)::\(account)", lastWarmed: lastWarmed)
        try env.profileStore.insert(p, snapshot: auth)
        return p
    }

    @MainActor
    private static func makeMonitor(env: AppEnvironment, warmerInterval: TimeInterval = 7 * 24 * 60 * 60) -> (UsageMonitor, RecordingWarmer) {
        let monitor = UsageMonitor()
        monitor.optimiser = UsageOptimiser(data: StoreData(), activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10], persistURL: nil)
        monitor.environment = env
        var cfg = AppConfig()
        cfg.warmerIntervalSeconds = warmerInterval
        monitor.config = cfg
        let recording = RecordingWarmer()
        monitor.warmer = recording
        return (monitor, recording)
    }

    // MARK: - Tests

    @Test("Never-warmed inactive profile gets warmed")
    func warmsNeverWarmed() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a", lastWarmed: Date())
        let inactive = try Self.insertProfile(env, label: "B", user: "u-b", account: "b", lastWarmed: nil)
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: active.id)
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed == [inactive.id])
    }

    @Test("Active profile is never warmed (would race the live poll)")
    func activeProfileExcluded() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a", lastWarmed: nil)
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: active.id)
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed.isEmpty)
    }

    @Test("Recently-warmed profile (within interval) is skipped")
    func recentlyWarmedSkipped() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a", lastWarmed: Date())
        _ = try Self.insertProfile(env, label: "B", user: "u-b", account: "b", lastWarmed: Date().addingTimeInterval(-60))  // 1 min ago
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: active.id)
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed.isEmpty)
    }

    @Test("Stale profile (older than interval) is warmed")
    func staleProfileWarmed() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a", lastWarmed: Date())
        let stale = try Self.insertProfile(env, label: "B", user: "u-b", account: "b", lastWarmed: Date().addingTimeInterval(-8 * 24 * 60 * 60))  // 8 days ago
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: active.id)
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed == [stale.id])
    }

    @Test("Only one profile warmed per call (one warm per poll cycle)")
    func oneWarmPerCall() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a", lastWarmed: Date())
        _ = try Self.insertProfile(env, label: "B", user: "u-b", account: "b", lastWarmed: nil)
        _ = try Self.insertProfile(env, label: "C", user: "u-c", account: "c", lastWarmed: nil)
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: active.id)
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed.count == 1)
    }

    @Test("Empty store is a no-op")
    func emptyStoreNoOp() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let (monitor, warmer) = Self.makeMonitor(env: env)

        await monitor.runWarmerIfDue(env: env, activeProfileID: "non-existent")
        let warmed = await warmer.warmedProfileIDs
        #expect(warmed.isEmpty)
    }
}
