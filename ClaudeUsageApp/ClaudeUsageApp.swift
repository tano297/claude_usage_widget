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
            // Compact readout: every active limit, labeled ("S0 W27 F45").
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

    // Rate-limit protection: coalesce bursts (menu-open, widget button, timer) into at most one live
    // fetch per `minFetchInterval`, and honor a 429 backoff so we never hammer the endpoint.
    private var lastFetchAt = Date.distantPast
    private var backoffUntil = Date.distantPast
    private let minFetchInterval: TimeInterval = 20

    init() {
        snapshot = SharedStore.load()
        // Bulletproof launch: enable the login item on first run so the agent (and thus the widget)
        // stays live across reboots. Only once — if you later turn it off in the menu, that sticks.
        if !UserDefaults.standard.bool(forKey: "didAutoEnableLoginItem") {
            UserDefaults.standard.set(true, forKey: "didAutoEnableLoginItem")
            setLaunchAtLogin(true)
        }
        if Self.notificationsEnabled { NotificationPoster.shared.prepare() }
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
        let now = Date()
        // Skip the network when we're inside a 429 backoff or a request happened very recently;
        // still repaint the widget so the age (and any last data) render.
        if now < backoffUntil || now.timeIntervalSince(lastFetchAt) < minFetchInterval {
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        isRefreshing = true
        lastFetchAt = now
        let (snap, creds, retryAfter) = await UsageClient.fetchSnapshot(using: cachedCreds)
        cachedCreds = creds   // reuse next time; nil re-reads the Keychain (e.g. after "Token expired")
        if let retryAfter { backoffUntil = Date().addingTimeInterval(max(retryAfter, 60)) }
        try? SharedStore.save(snap)
        snapshot = snap
        notifyThresholds(for: snap)
        isRefreshing = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Threshold notifications

    static let notificationsEnabledKey = "notificationsEnabled"
    private let thresholdStateKey = "thresholdNotifyState"

    /// Default ON — absence of the key means the user never opted out.
    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notificationsEnabledKey) == nil
            || UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    /// Runs the planner on every fresh snapshot. State always advances — even while muted — so
    /// re-enabling the toggle doesn't dump a backlog of crossings that happened silently.
    private func notifyThresholds(for snap: UsageSnapshot) {
        let stored = ThresholdPlanner.decodeState(UserDefaults.standard.string(forKey: thresholdStateKey))
        let (alerts, newState) = ThresholdPlanner.plan(snapshot: snap, state: stored, now: Date())
        UserDefaults.standard.set(ThresholdPlanner.encodeState(newState), forKey: thresholdStateKey)
        if Self.notificationsEnabled { NotificationPoster.shared.post(alerts) }
    }

    /// All active limits, labeled, for the menu bar glyph (see `menuBarSummary`).
    var menuBarText: String {
        menuBarSummary(snapshot)
    }
}

struct MenuContent: View {
    @ObservedObject var agent: UsageAgent
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var loginItemNote: String?
    @State private var notifyEnabled = UsageAgent.notificationsEnabled
    @State private var notifyNote: String?
    // Ticks once a minute so the popover's countdowns stay live while open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = agent.snapshot {
                HStack(spacing: 6) {
                    Text("Claude").font(.headline).foregroundStyle(ClaudeTheme.clay)
                    Text(s.planLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if agent.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                let hasData = s.session != nil || s.weeklyAll != nil || !(s.weeklyScoped?.isEmpty ?? true) || s.credits != nil
                if hasData {
                    UsageList(snapshot: s, now: now)
                    FreshnessRow(snapshot: s)
                    if s.stale, let error = s.error {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // No data yet: a single clear message (no misleading "updated 0s ago" row).
                    Text(s.error ?? "No usage yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Loading usage…").foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    loginItemNote = setLaunchAtLogin(on)
                    launchAtLogin = (SMAppService.mainApp.status == .enabled)   // reflect reality, not intent
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            if let loginItemNote {
                Button { SMAppService.openSystemSettingsLoginItems() } label: {
                    Label(loginItemNote, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }

            Toggle("Notify every 10% used / $10 spent", isOn: Binding(
                get: { notifyEnabled },
                set: { on in
                    notifyEnabled = on
                    UserDefaults.standard.set(on, forKey: UsageAgent.notificationsEnabledKey)
                    if on { NotificationPoster.shared.prepare() }
                    refreshNotifyNote()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            if let notifyNote {
                Button { openNotificationSettings() } label: {
                    Label(notifyNote, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }

            Text("Runs in the background and updates every \(Int(agent.refreshInterval / 60)) min. Tap ↻ on the widget for an instant refresh.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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
            launchAtLogin = (SMAppService.mainApp.status == .enabled)   // stay in sync with the system
            refreshNotifyNote()
            Task { await agent.refresh() }   // force a fresh reading whenever you open the menu
        }
    }

    /// Surface a settings hint when the toggle is on but macOS-level permission is denied.
    private func refreshNotifyNote() {
        guard notifyEnabled else { notifyNote = nil; return }
        Task {
            notifyNote = await NotificationPoster.shared.authorizationDenied()
                ? "Allow notifications for “Claude Usage” in System Settings ▸ Notifications." : nil
        }
    }
}

private func openNotificationSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

/// Registers/unregisters the app as a login item. Returns a user-facing note on failure or when
/// macOS parks it pending approval, else nil. Requires the app to be signed and in a stable
/// location (e.g. /Applications) — SMAppService silently refuses a DerivedData/quarantined copy.
@discardableResult
func setLaunchAtLogin(_ enabled: Bool) -> String? {
    do {
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                return "Enable “Claude Usage” in System Settings ▸ General ▸ Login Items."
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
        return nil
    } catch {
        NSLog("ClaudeUsage: login item toggle failed: \(error.localizedDescription)")
        return "Couldn't update the login item — open Login Items settings."
    }
}
