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
                dailyBudgetRemaining: monitor.metrics?.dailyBudgetRemaining ?? 1,
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
