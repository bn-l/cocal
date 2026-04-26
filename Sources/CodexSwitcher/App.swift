import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "App")

@main
struct CodexSwitcherApp: App {
    @State private var monitor: UsageMonitor

    init() {
        logger.info("CodexSwitcherApp initializing")
        Migration.runIfNeeded()
        let monitor = UsageMonitor()
        monitor.environment = AppEnvironment.shared
        // Prime the observable profile list before any view is constructed.
        // The popover uses `MenuBarExtra(.window)`, which keeps the SwiftUI
        // tree alive across opens — if we wait for `ProfileListView.init` or
        // `.task` to do this, the very first body evaluation can read an
        // empty `monitor.profiles` and never refresh on subsequent renders
        // (the user reported missing profile rows even though `poll()` was
        // logging the imported profile). Loading here is synchronous and
        // small: just a directory scan + a JSON decode per profile.
        monitor.reloadProfiles()
        logger.info("CodexSwitcherApp init: primed profiles count=\(monitor.profiles.count, privacy: .public)")
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            CalibratorIcon(
                calibrator: monitor.metrics?.calibrator ?? 0,
                sessionDeviation: monitor.metrics?.sessionDeviation ?? 0,
                dailyDeviation: monitor.metrics?.dailyDeviation ?? 0,
                dailyBudgetRemaining: monitor.metrics?.dailyBudgetRemaining,
                displayMode: monitor.displayMode,
                isSessionActive: monitor.metrics?.isSessionActive ?? true,
                hasError: monitor.hasError,
                needsRestart: monitor.needsRestart
            )
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                        logger.info("Running under test host — skipping polling")
                        return
                    }
                    logger.info("MenuBarExtra label task started, beginning polling")
                    await monitor.startPolling()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
