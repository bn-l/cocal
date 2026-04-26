import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "ProfileListView")

/// Test seam for `ProfileListReloadTests` and friends. When non-nil, every
/// `monitor.reloadProfiles()` call hands the freshly-loaded profile array to
/// this closure. Production code never reads it; only tests assign.
@MainActor
enum _ProfileListReloadObserver {
    static var didReload: (([Profile]) -> Void)?
}

/// Profile list per PLAN.md §2.3. Each row: status indicator (○/●/⚠), label,
/// plan tier, "5h XX% · wk XX%" utilization, trash icon. Footer hosts the
/// Import button.
///
/// The profile list itself lives on `UsageMonitor` (which is `@Observable`)
/// rather than in a local `@State`. With `MenuBarExtra(.window)` the SwiftUI
/// view tree is kept alive between popover opens, so a `@State` snapshotted
/// at first init would lock in stale data forever. Reading from the monitor
/// guarantees every render reflects the current store.
struct ProfileListView: View {
    let monitor: UsageMonitor
    /// Optional — only set when the view is presented as a separate page.
    /// In the inline-in-popover layout (PLAN.md Appendix A) this is `nil`.
    let onDismiss: (() -> Void)?

    @State private var inFlight = false
    @State private var pendingRemoval: Profile?

    private var importStatus: UsageMonitor.ImportStatus? { monitor.importStatus }

    init(monitor: UsageMonitor, onDismiss: (() -> Void)? = nil) {
        self.monitor = monitor
        self.onDismiss = onDismiss
        // Intentionally NO side-effect here. Round 3 confirmed that mutating
        // `monitor.profiles` inside an init that runs during a SwiftUI render
        // pass can leave the body of *this same instance* reading the stale
        // value (the user reported empty profile rows even though `poll()`
        // logs showed the profile loaded). The eager load happens once in
        // `CodexSwitcherApp.init`; ongoing refreshes happen via
        // `UsageMonitor.poll()` and `PopoverView`'s `.task` — both of which
        // mutate from outside any active view body.
    }

    private var profiles: [Profile] { monitor.profiles }
    private var activeID: String? { monitor.activeID }

    private var environment: AppEnvironment {
        monitor.environment ?? AppEnvironment.shared
    }

    var body: some View {
        let _ = logger.info("ProfileListView.body: profiles.count=\(monitor.profiles.count, privacy: .public) activeID=\(monitor.activeID ?? "nil", privacy: .public)")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Close profiles")
                }
            }

            if profiles.isEmpty {
                let _ = logger.info("ProfileListView: rendering EMPTY state")
                emptyState
            } else {
                let _ = logger.info("ProfileListView: rendering \(profiles.count, privacy: .public) row(s); first=\(profiles.first?.label ?? "?", privacy: .public)")
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    ProfileRow(
                        profile: profile,
                        isActive: profile.id == activeID,
                        inFlight: inFlight,
                        onSelect: { activate(profile) },
                        onRemove: { pendingRemoval = profile }
                    )
                }
            }

            if let status = importStatus {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            HStack {
                Spacer()
                Button {
                    runImport()
                } label: {
                    Label("Import credentials", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
                .disabled(inFlight)
                Spacer()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: monitor.importStatus)
        .onAppear { reload() }
        .confirmationDialog(
            "Remove profile?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { profile in
            Button("Remove \(profile.label)", role: .destructive) {
                remove(profile)
            }
            .pointerCursor()
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
            .pointerCursor()
        } message: { profile in
            Text("This deletes the stored credentials for \(profile.label).")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Codex profiles yet.")
                .font(.subheadline)
            Text("Run `codex login`, then click Import credentials below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func reload() {
        monitor.reloadProfiles()
    }

    private func runImport() {
        guard !inFlight else { return }
        inFlight = true
        monitor.importStatus = nil
        let env = environment
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let importer = env.makeImporter()
                let (outcome, auth) = try importer.runImport()
                switch outcome {
                case .imported(let profile):
                    monitor.showImportStatus(.init(
                        message: "Imported \(profile.label).",
                        isError: false
                    ))
                    if env.slotStore.loadActiveID() == nil {
                        try? env.slotStore.setActiveID(profile.id)
                    }
                case .duplicate(let existing):
                    monitor.showImportStatus(.init(
                        message: "No new credentials. \(existing.label) already imported — run `codex login` for a different ChatGPT account and click Import again.",
                        isError: false
                    ))
                case .refreshed(let existing):
                    // Route the write through the PerProfile actor so it
                    // serializes with any concurrent Warmer refresh and
                    // invalidates the actor's HTTPS cache.
                    let actor = env.perProfile(for: existing)
                    try await actor.importUpdate(with: auth)
                    monitor.showImportStatus(.init(
                        message: "Refreshed snapshot for \(existing.label).",
                        isError: false
                    ))
                }
                reload()
                // manualPoll re-runs `poll()`, which clears `noProfileImported`
                // when an active profile exists. Pre-fix only `.imported`
                // triggered this — `.refreshed` / `.duplicate` left the welcome
                // panel showing even though the credential was on disk.
                await monitor.manualPoll()
            } catch Importer.ImportError.noLiveAuth {
                monitor.showImportStatus(.init(
                    message: "No `auth.json` found. Run `codex login` first.",
                    isError: true
                ))
            } catch let Importer.ImportError.malformed(detail) {
                monitor.showImportStatus(.init(
                    message: "Live auth.json is malformed: \(detail)",
                    isError: true
                ))
            } catch Importer.ImportError.missingDedupClaims {
                monitor.showImportStatus(.init(
                    message: "Live auth.json is missing chatgpt_user_id / chatgpt_account_id claims. Re-run `codex login`.",
                    isError: true
                ))
            } catch {
                monitor.showImportStatus(.init(
                    message: "Import failed: \(error.localizedDescription)",
                    isError: true
                ))
            }
        }
    }

    private func activate(_ profile: Profile) {
        guard !inFlight, profile.warning == nil, profile.id != activeID else { return }
        inFlight = true
        let env = environment
        Task { @MainActor in
            defer { inFlight = false }
            let outgoingPair = env.activeProfileAndActor()
            let outgoingActor = outgoingPair?.1
            let incomingActor = env.perProfile(for: profile)
            do {
                _ = try await env.switcher.switchTo(
                    incoming: profile,
                    outgoingActor: outgoingActor,
                    incomingActor: incomingActor
                )
                monitor.needsRestart = true
                reload()
                await monitor.manualPoll()
            } catch {
                logger.error("Switch failed: \(String(describing: error), privacy: .public)")
                monitor.showImportStatus(.init(
                    message: "Switch failed: \(error.localizedDescription)",
                    isError: true
                ))
            }
        }
    }

    private func remove(_ profile: Profile) {
        let env = environment
        Task { @MainActor in
            do {
                try env.profileStore.remove(profile.id)
                if env.slotStore.loadActiveID() == profile.id {
                    try? env.slotStore.setActiveID(nil)
                }
                pendingRemoval = nil
                reload()
            } catch {
                logger.error("Remove failed: \(String(describing: error), privacy: .public)")
                monitor.showImportStatus(.init(
                    message: "Remove failed: \(error.localizedDescription)",
                    isError: true
                ))
            }
        }
    }

}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    let inFlight: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let plan = profile.planType, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(utilizationText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove \(profile.label)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture {
            if profile.warning == nil && !isActive {
                onSelect()
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let warning = profile.warning {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(warning.humanDescription)
        } else if isActive {
            Image(systemName: "circle.inset.filled")
                .foregroundStyle(Color.accentColor)
                .help("Active profile")
        } else {
            Image(systemName: inFlight ? "circle.dotted" : "circle")
                .foregroundStyle(.secondary)
                .help("Click to switch to \(profile.label)")
        }
    }

    private var utilizationText: String {
        let session = profile.primaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let weekly = profile.secondaryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        return "5h \(session) · wk \(weekly)"
    }
}
