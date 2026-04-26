import Foundation
import UserNotifications
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "Notifier")

/// Test seam — anything that can post user-visible notifications. Production
/// uses `Notifier`; UsageMonitor unit tests inject a recording stub.
public protocol NotificationPosting: Sendable {
    func post(title: String, body: String) async
}

/// Thin wrapper around `UNUserNotificationCenter` for the auto-switch flow
/// (PLAN.md §2.3). We request authorization lazily on first post — the user is
/// already in a "Codex usage near 90%" state when the first notification fires,
/// so the prompt arrives at a moment they understand.
public actor Notifier: NotificationPosting {
    private var requestedAuthorization = false

    public init() {}

    public func post(title: String, body: String) async {
        await ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Posted notification: \(title, privacy: .public)")
        } catch {
            logger.warning("Failed to post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureAuthorization() async {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.warning("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
