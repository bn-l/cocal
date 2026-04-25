import SwiftUI

struct PopoverView: View {
    let monitor: UsageMonitor
    @State private var showingErrors = false
    @State private var showingStats = false
    @State private var showingProfiles = false
    @State private var stats: UsageStats?
    @State private var keyringMode: CodexConfig.StorageMode = .file
    @State private var showKeyringPrompt = false
    @State private var keyringRewriteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingErrors {
                errorListView
            } else if showingStats, let stats {
                StatsView(stats: stats, onDismiss: { showingStats = false })
            } else if showingProfiles {
                ProfileListView(monitor: monitor, onDismiss: { showingProfiles = false })
            } else {
                ZStack(alignment: .top) {
                    mainContent
                        .padding(.top, monitor.hasError ? 24 : 0)
                    if monitor.hasError {
                        errorButton
                    }
                }
            }

            Divider()

            HStack {
                if let lastUpdated = monitor.lastUpdated {
                    Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .disabled(monitor.isLoading)
                Button {
                    monitor.toggleDisplayMode()
                } label: {
                    Image(systemName: monitor.displayMode == .calibrator
                        ? "chart.bar.fill"
                        : "gauge.with.needle")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(monitor.displayMode == .calibrator ? "Switch to dual bar" : "Switch to calibrator")
                Button {
                    stats = monitor.computeStats()
                    showingStats = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("View stats")
                Button {
                    showingProfiles = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Profiles")
                Button {
                    monitor.autoSwitchEnabled.toggle()
                } label: {
                    Image(systemName: monitor.autoSwitchEnabled
                        ? "arrow.left.arrow.right.circle.fill"
                        : "arrow.left.arrow.right.circle")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(monitor.autoSwitchEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .help(monitor.autoSwitchEnabled ? "Auto-switch on (click to disable)" : "Auto-switch off (click to enable)")
                if monitor.needsRestart {
                    Button {
                        monitor.clearNeedsRestart()
                    } label: {
                        Label("Restart Codex", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Restart any running Codex CLI / Codex.app to pick up the new credentials, then click to dismiss.")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            keyringMode = CodexConfig().detectMode()
            if keyringMode.needsFileMode {
                showKeyringPrompt = true
            }
        }
        .onDisappear {
            showingErrors = false
            showingStats = false
            showingProfiles = false
        }
        .onChange(of: monitor.hasError) { _, hasError in
            if !hasError { showingErrors = false }
        }
        .alert("Codex is using Keychain storage", isPresented: $showKeyringPrompt) {
            Button("Switch to file mode") {
                do {
                    try CodexConfig().switchToFileMode()
                    keyringMode = .file
                    keyringRewriteError = nil
                } catch {
                    keyringRewriteError = error.localizedDescription
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("To use codex-switcher, change Codex to file storage and re-run `codex login`. Your `auth.json` will then live at `~/.codex/auth.json` (mode 0600) — the same threat model as our own profile snapshots.")
        }
        .alert("Couldn't rewrite config.toml", isPresented: Binding(
            get: { keyringRewriteError != nil },
            set: { if !$0 { keyringRewriteError = nil } }
        ), presenting: keyringRewriteError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let metrics = monitor.metrics {
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
