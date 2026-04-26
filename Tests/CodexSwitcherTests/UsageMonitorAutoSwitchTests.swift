import Testing
import Foundation
@testable import CodexSwitcher

// MARK: - Recording stubs

/// Captures every `post` call so tests can assert on title/body without going
/// near `UNUserNotificationCenter`.
actor RecordingNotifier: NotificationPosting {
    struct Posted: Equatable, Sendable {
        let title: String
        let body: String
    }
    var posts: [Posted] = []
    func post(title: String, body: String) async {
        posts.append(Posted(title: title, body: body))
    }
}

@Suite("UsageMonitor — autoSwitchIfNeeded gates", .serialized)
@MainActor
struct UsageMonitorAutoSwitchTests {

    private static func tempEnvironment() throws -> (AppEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-switch-tests-\(UUID().uuidString)")
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

    private static func insertProfile(_ env: AppEnvironment, label: String, user: String, account: String, primaryUsedPercent: Double? = nil, lastWarmed: Date? = nil, warning: ProfileWarning? = nil) throws -> Profile {
        let auth = try makeAuth(user: user, account: account)
        let p = Profile(
            label: label,
            dedupKey: "\(user)::\(account)",
            lastWarmed: lastWarmed,
            primaryUsedPercent: primaryUsedPercent,
            warning: warning
        )
        try env.profileStore.insert(p, snapshot: auth)
        return p
    }

    /// Build a UsageMonitor wired to the recording notifier and a known env.
    @MainActor
    private static func makeMonitor(env: AppEnvironment, autoSwitch: Bool) -> (UsageMonitor, RecordingNotifier) {
        let monitor = UsageMonitor()
        let optimiser = UsageOptimiser(
            data: StoreData(),
            activeHoursPerDay: [10, 10, 10, 10, 10, 10, 10],
            persistURL: nil
        )
        monitor.optimiser = optimiser
        monitor.environment = env
        var cfg = AppConfig()
        cfg.autoSwitchEnabled = autoSwitch
        cfg.autoSwitchThresholdPercent = 90
        cfg.autoSwitchMinSessionMinutesLeft = 30
        monitor.config = cfg
        let notifier = RecordingNotifier()
        monitor.notifier = notifier
        return (monitor, notifier)
    }

    // MARK: - Tests

    @Test("autoSwitchEnabled=false: nothing fires even at 100%")
    func disabledIsNoOp() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u", account: "a")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: false)

        await monitor.autoSwitchIfNeeded(
            env: env,
            activeProfile: active,
            primaryUsedPercent: 100,
            sessionMinsLeft: 240
        )
        let posts = await notifier.posts
        #expect(posts.isEmpty)
        #expect(monitor.needsRestart == false)
    }

    @Test("89% does not trigger; 90% does")
    func thresholdBoundary() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u", account: "a")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        // Below threshold → no post.
        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 89, sessionMinsLeft: 240)
        var posts = await notifier.posts
        #expect(posts.isEmpty)

        // At threshold, with no eligible candidate → exactly one "abort" notification.
        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 90, sessionMinsLeft: 240)
        posts = await notifier.posts
        #expect(posts.count == 1)
        #expect(posts.first?.title.contains("90%") == true)
    }

    @Test("sessionMinsLeft must exceed config (>30) to fire")
    func sessionMinsBoundary() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u", account: "a")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        // sessionMinsLeft == config.autoSwitchMinSessionMinutesLeft (30) → not greater than → exit
        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 30)
        #expect(await notifier.posts.isEmpty)

        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 31)
        #expect(await notifier.posts.count == 1)
    }

    @Test("Latch: a single breach yields one notification across many polls")
    func latchPreventsRefiring() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u", account: "a")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        for _ in 0..<5 {
            await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 240)
        }
        #expect(await notifier.posts.count == 1)
    }

    @Test("Latch resets when usage drops below threshold")
    func latchResetsBelowThreshold() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u", account: "a")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 240)
        #expect(await notifier.posts.count == 1)

        // Drop below threshold — latch resets.
        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 50, sessionMinsLeft: 240)

        // Breach again — second notification fires.
        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 240)
        #expect(await notifier.posts.count == 2)
    }

    @Test("No candidate available: notification body explains no fresh profile")
    func noCandidateMessaging() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a")
        // Insert a stale profile — primaryUsedPercent unset, so picker rejects it.
        _ = try Self.insertProfile(env, label: "B", user: "u-b", account: "b")
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 240)
        let posts = await notifier.posts
        #expect(posts.count == 1)
        #expect(posts.first?.body.contains("No fresh low-usage profile") == true)
    }

    @Test("Warning candidate is excluded — only fresh, healthy, low-usage profiles win")
    func warningCandidateExcluded() async throws {
        let (env, root) = try Self.tempEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try Self.insertProfile(env, label: "A", user: "u-a", account: "a")
        _ = try Self.insertProfile(env, label: "B-warn",
                                   user: "u-b", account: "b",
                                   primaryUsedPercent: 10,
                                   lastWarmed: Date(),
                                   warning: .refreshExpired)
        let (monitor, notifier) = Self.makeMonitor(env: env, autoSwitch: true)

        await monitor.autoSwitchIfNeeded(env: env, activeProfile: active, primaryUsedPercent: 95, sessionMinsLeft: 240)
        // Picker rejects warning profile → abort path
        let posts = await notifier.posts
        #expect(posts.count == 1)
        #expect(posts.first?.body.contains("No fresh low-usage profile") == true)
    }
}
