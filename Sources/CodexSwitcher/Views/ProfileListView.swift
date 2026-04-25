import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "ProfileListView")

/// Profile list per PLAN.md §2.3. Each row: status indicator (○/●/⚠), label,
/// plan tier, "5h XX% · wk XX%" utilization, trash icon. Footer hosts the
/// Import button.
struct ProfileListView: View {
    let monitor: UsageMonitor
    let onDismiss: () -> Void

    @State private var profiles: [Profile] = []
    @State private var activeID: String?
    @State private var inFlight = false
    @State private var importStatus: ImportStatus?
    @State private var pendingRemoval: Profile?

    private var environment: AppEnvironment {
        monitor.environment ?? AppEnvironment.shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                }
                .frame(maxHeight: 220)
            }

            if let status = importStatus {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    runImport()
                } label: {
                    Label("Import credentials", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inFlight)
                Spacer()
            }
        }
        .task { reload() }
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
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
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
        profiles = environment.profileStore.loadAll()
        activeID = environment.slotStore.loadActiveID()
    }

    private func runImport() {
        guard !inFlight else { return }
        inFlight = true
        importStatus = nil
        let env = environment
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let importer = env.makeImporter()
                let (outcome, _) = try importer.runImport()
                switch outcome {
                case .imported(let profile):
                    importStatus = ImportStatus(
                        message: "Imported \(profile.label).",
                        isError: false
                    )
                    if env.slotStore.loadActiveID() == nil {
                        try? env.slotStore.setActiveID(profile.id)
                    }
                    await monitor.manualPoll()
                case .duplicate(let existing):
                    importStatus = ImportStatus(
                        message: "No new credentials. \(existing.label) already imported — run `codex login` for a different ChatGPT account and click Import again.",
                        isError: false
                    )
                case .refreshed(let existing):
                    importStatus = ImportStatus(
                        message: "Refreshed snapshot for \(existing.label).",
                        isError: false
                    )
                }
                reload()
            } catch Importer.ImportError.noLiveAuth {
                importStatus = ImportStatus(
                    message: "No `auth.json` found. Run `codex login` first.",
                    isError: true
                )
            } catch let Importer.ImportError.malformed(detail) {
                importStatus = ImportStatus(
                    message: "Live auth.json is malformed: \(detail)",
                    isError: true
                )
            } catch Importer.ImportError.missingDedupClaims {
                importStatus = ImportStatus(
                    message: "Live auth.json is missing chatgpt_user_id / chatgpt_account_id claims. Re-run `codex login`.",
                    isError: true
                )
            } catch {
                importStatus = ImportStatus(
                    message: "Import failed: \(error.localizedDescription)",
                    isError: true
                )
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
                importStatus = ImportStatus(
                    message: "Switch failed: \(error.localizedDescription)",
                    isError: true
                )
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
                importStatus = ImportStatus(
                    message: "Remove failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    private struct ImportStatus: Equatable {
        let message: String
        let isError: Bool
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
            .help("Remove \(profile.label)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
