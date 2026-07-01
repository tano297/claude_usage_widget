import SwiftUI
import AppKit
import WidgetKit
import ServiceManagement

// The container app runs as a background agent (LSUIElement): no Dock icon, just a small menu
// bar item. Its job is to read the Keychain token, call the usage endpoint, write the snapshot
// to the App Group, and nudge the widget to reload. The Notification Center widget is the main
// surface; the menu bar item is a convenient control + at-a-glance readout.

@main
struct ClaudeUsageApp: App {
    @StateObject private var agent = UsageAgent()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(agent: agent)
        } label: {
            // Compact readout: the most-consumed active limit.
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text(agent.menuBarText).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageAgent: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false

    /// Fixed cadence. WidgetKit also self-refreshes countdowns between writes.
    let refreshInterval: TimeInterval = 180
    private var timer: Timer?

    /// In-memory credential cache so normal polls never hit the Keychain (which is what triggers the
    /// macOS access prompt). Read from the Keychain only at first launch and near token expiry.
    private var cachedCreds: ClaudeCredentials?

    init() {
        snapshot = SharedStore.load()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // The widget's refresh button posts a Darwin signal → do a live fetch here.
        RefreshSignal.startObserving()
        NotificationCenter.default.addObserver(forName: RefreshSignal.didRequestRefresh,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }   // serialize: never run two refreshes at once
        isRefreshing = true
        let (snap, creds) = await UsageClient.fetchSnapshot(using: cachedCreds)
        cachedCreds = creds   // reuse next time; nil re-reads the Keychain (e.g. after "Token expired")
        try? SharedStore.save(snap)
        snapshot = snap
        isRefreshing = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Highest active utilization across the limits, for the menu bar glyph.
    var menuBarText: String {
        guard let s = snapshot else { return "—" }
        let bars = [s.session, s.weeklyAll, s.weeklyOpus].compactMap { $0 }
        guard let top = bars.max(by: { $0.percent < $1.percent }) else { return "—" }
        return percentString(top.percent)
    }
}

struct MenuContent: View {
    @ObservedObject var agent: UsageAgent
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    // Ticks once a minute so the popover's countdowns stay live while open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = agent.snapshot {
                HStack(spacing: 6) {
                    Text("Claude").font(.headline)
                    Text(s.planLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if agent.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                if s.session == nil && s.weeklyAll == nil && s.weeklyOpus == nil && s.credits == nil {
                    Text(s.error ?? "No usage yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    UsageList(snapshot: s, now: now)
                }
                FreshnessRow(snapshot: s)
                if s.stale, let error = s.error {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Loading usage…").foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in launchAtLogin = on; setLaunchAtLogin(on) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            HStack {
                Button {
                    Task { await agent.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 290)
        .onReceive(tick) { now = $0 }
        .onAppear {
            now = Date()
            Task { await agent.refresh() }   // force a fresh reading whenever you open the menu
        }
    }
}

func setLaunchAtLogin(_ enabled: Bool) {
    do {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    } catch {
        NSLog("ClaudeUsage: login item toggle failed: \(error.localizedDescription)")
    }
}

