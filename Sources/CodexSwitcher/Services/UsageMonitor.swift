import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Monitor")

struct AppError: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let timestamp: Date

    init(message: String, timestamp: Date = Date()) {
        self.message = message
        self.timestamp = timestamp
    }
}

@Observable
@MainActor
final class UsageMonitor {
    var metrics: UsageMetrics? {
        didSet {
            logger.trace("metrics updated: calibrator=\(self.metrics?.calibrator ?? -99, privacy: .public)")
        }
    }
    var errors: [AppError] = []
    var hasError: Bool { !errors.isEmpty }
    var isLoading = false
    var lastUpdated: Date?
    var config = AppConfig.load()
    var displayMode: MenuBarDisplayMode {
        get { config.menuBarDisplayMode }
        set {
            config.menuBarDisplayMode = newValue
            config.save()
        }
    }
    var autoSwitchEnabled: Bool {
        get { config.autoSwitchEnabled }
        set {
            config.autoSwitchEnabled = newValue
            config.save()
        }
    }
    var needsRestart: Bool = false
    private var napActivity: (any NSObjectProtocol)?

    /// Injected by the app entry point; tests construct their own `UsageMonitor`
    /// and exercise `processResponse` directly without going through this.
    var environment: AppEnvironment?

    /// Test seams. Production uses live implementations; tests inject stubs.
    @ObservationIgnored var notifier: any NotificationPosting = Notifier()
    @ObservationIgnored var warmer: (any WarmingService)?
    @ObservationIgnored var autoSwitchPicker = AutoSwitchPicker()
    /// Profile id that already triggered an auto-switch attempt this poll cycle —
    /// prevents re-firing every 5 minutes while still over threshold.
    @ObservationIgnored private var lastAutoSwitchAttemptForProfileID: String?

    // internal(set) for test injection
    var optimiser: UsageOptimiser?

    func computeStats() -> UsageStats? {
        optimiser?.computeStats()
    }

    func toggleDisplayMode() {
        displayMode = displayMode == .calibrator ? .dualBar : .calibrator
    }

    func manualPoll() async {
        logger.info("Manual poll triggered")
        await poll()
    }

    func startPolling() async {
        logger.info("startPolling: pollInterval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        napActivity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Periodic API polling")

        ensureOptimiser()

        logger.info("Starting initial poll")
        await poll()

        logger.info("Entering polling loop: interval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            logger.debug("Poll timer fired")
            await poll()
        }
        logger.info("Polling loop exited: cancelled=\(Task.isCancelled, privacy: .public)")
    }

    func processResponse(
        sessionUsagePct: Double,
        weeklyUsagePct: Double,
        sessionMinsLeft: Double,
        weeklyMinsLeft: Double,
        weeklyResetAt: Date? = nil,
        isSessionActive: Bool = true
    ) {
        logger.debug("Raw values: sessionUsagePct=\(sessionUsagePct, privacy: .public) weeklyUsagePct=\(weeklyUsagePct, privacy: .public) sessionMinsLeft=\(sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")

        ensureOptimiser()

        let result = optimiser!.recordPoll(
            sessionUsage: sessionUsagePct,
            sessionRemaining: sessionMinsLeft,
            weeklyUsage: weeklyUsagePct,
            weeklyRemaining: weeklyMinsLeft,
            weeklyResetAt: weeklyResetAt
        )

        metrics = UsageMetrics(
            sessionUsagePct: sessionUsagePct,
            weeklyUsagePct: weeklyUsagePct,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: weeklyMinsLeft,
            calibrator: result.calibrator,
            sessionTarget: result.target,
            sessionDeviation: result.sessionDeviation,
            dailyDeviation: result.dailyDeviation,
            dailyBudgetRemaining: result.dailyBudgetRemaining,
            weeklyDeviation: result.weeklyDeviation,
            sessionElapsedPct: (UsageOptimiser.sessionMinutes - sessionMinsLeft) / UsageOptimiser.sessionMinutes * 100,
            weeklyElapsedPct: (UsageOptimiser.weekMinutes - weeklyMinsLeft) / UsageOptimiser.weekMinutes * 100,
            isSessionActive: isSessionActive,
            timestamp: Date()
        )
        errors.removeAll()
        lastUpdated = Date()

        logger.info("Poll complete: calibrator=\(result.calibrator, privacy: .public) target=\(result.target, privacy: .public) optimalRate=\(result.optimalRate, privacy: .public)")
    }

    private func ensureOptimiser() {
        guard optimiser == nil else { return }
        optimiser = UsageOptimiser(
            data: DataStore.load(),
            activeHoursPerDay: config.activeHoursPerDay,
            persistURL: DataStore.defaultURL
        )
    }

    private func appendError(_ message: String) {
        logger.debug("Error recorded: \(message, privacy: .public)")
        errors.append(AppError(message: message))
        if errors.count > 10 { errors.removeFirst(errors.count - 10) }
    }

    private func poll() async {
        logger.debug("poll() start")
        isLoading = true
        defer {
            isLoading = false
            logger.debug("poll() end")
        }

        let env = environment ?? AppEnvironment.shared
        guard let (profile, perProfile) = env.activeProfileAndActor() else {
            appendError("No Codex profile imported. Click Import credentials, or run `codex login` first.")
            logger.warning("No active profile — skipping poll")
            return
        }

        do {
            let response = try await perProfile.usage()
            let (primary, secondary) = response.resolvedWindows
            if primary == nil { logger.warning("Codex usage response missing primary window") }
            if secondary == nil { logger.warning("Codex usage response missing secondary window") }
            let sessionMinsLeft = minutesUntil(primary?.resetsAt)
            let weeklyMinsLeft = minutesUntil(secondary?.resetsAt)
            processResponse(
                sessionUsagePct: primary?.usedPercent ?? 0,
                weeklyUsagePct: secondary?.usedPercent ?? 0,
                sessionMinsLeft: sessionMinsLeft,
                weeklyMinsLeft: weeklyMinsLeft,
                weeklyResetAt: secondary?.resetsAt,
                isSessionActive: primary != nil && sessionMinsLeft > 0
            )
            logger.info("Codex poll ok: profile=\(profile.label, privacy: .public) primary%=\(primary?.usedPercent ?? -1, privacy: .public) secondary%=\(secondary?.usedPercent ?? -1, privacy: .public)")
            await runWarmerIfDue(env: env, activeProfileID: profile.id)
            await autoSwitchIfNeeded(
                env: env,
                activeProfile: profile,
                primaryUsedPercent: primary?.usedPercent,
                sessionMinsLeft: sessionMinsLeft
            )
        } catch let BackendError.refreshFailure(reason) {
            appendError("Refresh failed for \(profile.label): \(reason.rawValue). Re-run `codex login` for that account.")
            logger.error("Refresh failure: profile=\(profile.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        } catch {
            appendError(error.localizedDescription)
            logger.error("Poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Walk inactive profiles; warm the first one whose `lastWarmed` is older
    /// than `warmerIntervalSeconds` (or has never been warmed). One warm per
    /// poll cycle keeps refresh-token rotation calls spaced out and avoids
    /// thundering-herd on app start.
    func runWarmerIfDue(env: AppEnvironment, activeProfileID: String) async {
        let cutoff = Date().addingTimeInterval(-config.warmerIntervalSeconds)
        let due = env.profileStore.loadAll().first { profile in
            guard profile.id != activeProfileID else { return false }
            guard let last = profile.lastWarmed else { return true }
            return last < cutoff
        }
        guard let due else { return }
        logger.info("Warming profile=\(due.label, privacy: .public)")
        let actor = env.perProfile(for: due)
        let svc = warmer ?? Warmer(store: env.profileStore)
        if warmer == nil { warmer = svc }
        _ = await svc.warm(profile: due, actor: actor)
    }

    func autoSwitchIfNeeded(
        env: AppEnvironment,
        activeProfile: Profile,
        primaryUsedPercent: Double?,
        sessionMinsLeft: Double
    ) async {
        guard config.autoSwitchEnabled else { return }
        guard let primary = primaryUsedPercent else { return }
        guard primary >= config.autoSwitchThresholdPercent else {
            // Reset gate once we drop below threshold so the next breach can fire.
            if lastAutoSwitchAttemptForProfileID == activeProfile.id {
                lastAutoSwitchAttemptForProfileID = nil
            }
            return
        }
        guard sessionMinsLeft > config.autoSwitchMinSessionMinutesLeft else { return }
        guard lastAutoSwitchAttemptForProfileID != activeProfile.id else { return }
        lastAutoSwitchAttemptForProfileID = activeProfile.id

        let candidates = env.profileStore.loadAll()
        guard let winner = autoSwitchPicker.pick(
            among: candidates,
            excluding: activeProfile.id
        ) else {
            logger.warning("Auto-switch aborted: no fresh low-usage candidate (active=\(activeProfile.label, privacy: .public) primary%=\(primary, privacy: .public))")
            await notifier.post(
                title: "Codex usage at \(Int(primary))%",
                body: "No fresh low-usage profile is available. Run a manual refresh to warm candidates, or switch manually."
            )
            return
        }

        do {
            let outgoingActor = env.perProfile(for: activeProfile)
            let incomingActor = env.perProfile(for: winner)
            _ = try await env.switcher.switchTo(
                incoming: winner,
                outgoingActor: outgoingActor,
                incomingActor: incomingActor
            )
            needsRestart = true
            logger.info("Auto-switched profile=\(activeProfile.label, privacy: .public) → \(winner.label, privacy: .public)")
            await notifier.post(
                title: "Switched profile",
                body: "\(activeProfile.label) → \(winner.label). Restart Codex for the new account to take effect."
            )
            await poll()
        } catch {
            logger.error("Auto-switch failed: \(String(describing: error), privacy: .public)")
            appendError("Auto-switch failed: \(error.localizedDescription)")
        }
    }

    func clearNeedsRestart() {
        needsRestart = false
    }

    func minutesUntil(_ isoString: String?) -> Double {
        guard let date = parseISO8601Date(isoString), let str = isoString else {
            return 0
        }
        let mins = max(date.timeIntervalSinceNow / 60, 0)
        logger.trace("minutesUntil: input=\(str, privacy: .public) minutes=\(mins, privacy: .public)")
        return mins
    }

    /// Same percent / minute mapping as the live `poll()` path, for callers that
    /// already have a `UsageResponse` in hand (e.g. the warmer).
    func minutesUntil(_ date: Date?) -> Double {
        guard let date else { return 0 }
        return max(date.timeIntervalSinceNow / 60, 0)
    }

    private func parseISO8601Date(_ isoString: String?) -> Date? {
        guard let str = isoString else {
            logger.trace("parseISO8601Date: nil input")
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) {
            return date
        }
        logger.warning("Failed to parse ISO8601 date: input=\(str, privacy: .public)")
        return nil
    }
}

// MARK: - Config

enum MenuBarDisplayMode: String, Codable, Sendable {
    case calibrator
    case dualBar
}

struct AppConfig: Codable, Sendable {
    var activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10]
    var pollIntervalSeconds: Int = 300
    var menuBarDisplayMode: MenuBarDisplayMode = .calibrator
    var autoSwitchEnabled: Bool = false
    var autoSwitchThresholdPercent: Double = 90
    var autoSwitchMinSessionMinutesLeft: Double = 30
    var warmerIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60

    init(
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        pollIntervalSeconds: Int = 300,
        menuBarDisplayMode: MenuBarDisplayMode = .calibrator,
        autoSwitchEnabled: Bool = false,
        autoSwitchThresholdPercent: Double = 90,
        autoSwitchMinSessionMinutesLeft: Double = 30,
        warmerIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.activeHoursPerDay = activeHoursPerDay
        self.pollIntervalSeconds = pollIntervalSeconds
        self.menuBarDisplayMode = menuBarDisplayMode
        self.autoSwitchEnabled = autoSwitchEnabled
        self.autoSwitchThresholdPercent = autoSwitchThresholdPercent
        self.autoSwitchMinSessionMinutesLeft = autoSwitchMinSessionMinutesLeft
        self.warmerIntervalSeconds = warmerIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeHoursPerDay = try container.decodeIfPresent([Double].self, forKey: .activeHoursPerDay) ?? [10, 10, 10, 10, 10, 10, 10]
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .calibrator
        autoSwitchEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSwitchEnabled) ?? false
        autoSwitchThresholdPercent = try container.decodeIfPresent(Double.self, forKey: .autoSwitchThresholdPercent) ?? 90
        autoSwitchMinSessionMinutesLeft = try container.decodeIfPresent(Double.self, forKey: .autoSwitchMinSessionMinutesLeft) ?? 30
        warmerIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .warmerIntervalSeconds) ?? 7 * 24 * 60 * 60
    }

    private static let configURL = Migration.appSupportDirectory
        .appendingPathComponent("config.json")

    static func load() -> AppConfig {
        load(from: configURL)
    }

    static func load(from url: URL) -> AppConfig {
        let path = url.path()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.info("Config file not readable at \(path, privacy: .public): \(error.localizedDescription, privacy: .public) — using defaults")
            return AppConfig()
        }
        guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            logger.error("Config file at \(path, privacy: .public) exists but failed to decode (\(data.count, privacy: .public) bytes) — using defaults")
            return AppConfig()
        }
        logger.info("Config loaded: path=\(path, privacy: .public) activeHoursPerDay=\(config.activeHoursPerDay, privacy: .public) pollIntervalSeconds=\(config.pollIntervalSeconds, privacy: .public) displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        return config
    }

    func save() {
        Self.save(self, to: Self.configURL)
    }

    static func save(_ config: AppConfig, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else {
            logger.error("Failed to encode config for save")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            logger.info("Config saved: displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        } catch {
            logger.error("Failed to write config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
