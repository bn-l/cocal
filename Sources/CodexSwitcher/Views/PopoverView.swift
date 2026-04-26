import SwiftUI

struct PopoverView: View {
    let monitor: UsageMonitor
    @State private var showingErrors = false
    @State private var showingStats = false
    @State private var stats: UsageStats?
    @State private var keyringMode: CodexConfig.StorageMode = .file
    @State private var showKeyringPrompt = false
    @State private var keyringRewriteError: String?

    /// PLAN.md Appendix A specifies the Profiles section sits inline between
    /// metrics and the footer — not behind a separate page. Test anchor for
    /// PopoverInlineProfilesTests.
    static let embedsProfileSectionInline: Bool = true

    var body: some View {
        @Bindable var monitor = monitor
        return VStack(alignment: .leading, spacing: 12) {
            if showingErrors {
                errorListView
            } else if showingStats, let stats {
                StatsView(stats: stats, onDismiss: { showingStats = false })
            } else {
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        mainContent
                            .padding(.top, monitor.hasError && !monitor.noProfileImported ? 24 : 0)
                        if !monitor.noProfileImported {
                            Divider()
                            ProfileListView(monitor: monitor)
                        }
                    }
                    if monitor.hasError && !monitor.noProfileImported {
                        errorButton
                    }
                }
            }

            Divider()

            // Footer: flex space-between via Spacer(minLength: 0) between
            // every adjacent pair. HStack(spacing: 0) so Spacers own the math.
            HStack(spacing: 0) {
                // Refresh icon LEFT of timestamp; "Updated" dropped per user request.
                Button {
                    Task { await monitor.manualPoll() }
                } label: {
                    if monitor.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .disabled(monitor.isLoading)
                .help("Refresh usage now")
                if let lastUpdated = monitor.lastUpdated {
                    Text("\(lastUpdated, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 3)
                }
                Spacer(minLength: 0)
                Button {
                    monitor.toggleDisplayMode()
                } label: {
                    Image(systemName: monitor.displayMode == .calibrator
                        ? "chart.bar.fill"
                        : "gauge.with.needle")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(monitor.displayMode == .calibrator ? "Switch to dual bar" : "Switch to calibrator")
                Spacer(minLength: 0)
                Button {
                    stats = monitor.computeStats()
                    showingStats = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("View stats")
                Spacer(minLength: 0)
                Toggle("Auto switch", isOn: $monitor.autoSwitchEnabled)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(.purple)
                    .font(.caption2)
                    .pointerCursor()
                    .help(monitor.autoSwitchEnabled ? "Auto-switch on (click to disable)" : "Auto-switch off (click to enable)")
                if monitor.needsRestart {
                    Spacer(minLength: 0)
                    Button {
                        monitor.clearNeedsRestart()
                    } label: {
                        Label("Restart Codex", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .foregroundStyle(.orange)
                    .help("Restart any running Codex CLI / Codex.app to pick up the new credentials, then click to dismiss.")
                }
                Spacer(minLength: 0)
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task {
            // Re-sync the observable profile list every time the popover
            // opens. `MenuBarExtra(.window)` keeps the SwiftUI tree alive
            // across opens, so without this an out-of-band store change
            // (e.g. a CLI delete) wouldn't surface until the next poll.
            // `.task` runs on the MainActor and is cancelled on disappear,
            // so this is a one-shot sync, not a leak.
            monitor.reloadProfiles()
        }
        .onAppear {
            keyringMode = CodexConfig().detectMode()
            if keyringMode.needsFileMode {
                showKeyringPrompt = true
            }
        }
        .onDisappear {
            showingErrors = false
            showingStats = false
        }
        .onChange(of: monitor.hasError) { _, hasError in
            if !hasError { showingErrors = false }
        }
        .alert("Pin Codex to file storage", isPresented: $showKeyringPrompt) {
            Button("Pin to file mode") {
                do {
                    try CodexConfig().switchToFileMode()
                    keyringMode = .file
                    keyringRewriteError = nil
                } catch {
                    keyringRewriteError = error.localizedDescription
                }
            }
            .pointerCursor()
            Button("Not now", role: .cancel) {}
            .pointerCursor()
        } message: {
            Text("""
            codex-switcher needs Codex's credentials on disk so it can swap between profiles.

            Your config has cli_auth_credentials_store set to keyring or auto, which means Codex may store credentials in the macOS Keychain. The switcher can't read or replace those.

            Pin Codex to file mode by adding this line to ~/.codex/config.toml:

                cli_auth_credentials_store = "file"

            then re-run `codex login`. Your auth.json will live at ~/.codex/auth.json (mode 0600).

            Tap "Pin to file mode" and we'll add the line for you (existing comments and keys are preserved). You'll still need to re-run `codex login` afterwards if Codex had stored your credential in the Keychain, so it gets moved into the file.
            """)
        }
        .alert("Couldn't rewrite config.toml", isPresented: Binding(
            get: { keyringRewriteError != nil },
            set: { if !$0 { keyringRewriteError = nil } }
        ), presenting: keyringRewriteError) { _ in
            Button("OK", role: .cancel) {}
                .pointerCursor()
        } message: { error in
            Text(error)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if monitor.noProfileImported {
            // First-run / no-profile state — make Import the obvious next move.
            // PLAN.md §2.3 calls Import "the only 'add' path", so we surface
            // the full ProfileListView (which owns the Import button + status
            // copy) instead of a stub error.
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("Welcome to Codex Switcher")
                        .font(.headline)
                    Text("Run `codex login` in a terminal, then click Import to capture the credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                ProfileListView(monitor: monitor)
            }
        } else if let metrics = monitor.metrics {
            MetricsView(metrics: metrics)
        } else if monitor.hasError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Unable to fetch usage data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    private var errorButton: some View {
        Button {
            showingErrors = true
        } label: {
            Label("View errors", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var errorListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Errors")
                    .font(.headline)
                Spacer()
                Button {
                    showingErrors = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Close errors")
            }
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(monitor.errors.reversed().enumerated()), id: \.element.id) { index, error in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(error.message)
                                .font(.caption)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}
