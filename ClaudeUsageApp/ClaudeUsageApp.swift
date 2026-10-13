import SwiftUI
import AppKit
import WidgetKit
import ServiceManagement

// The container app runs as a non-sandboxed background agent (LSUIElement) so it can launch the
// Claude CLI. It writes the parsed snapshot to Application Support and nudges the widget to reload;
// the menu bar item is a convenient control + at-a-glance readout.

@main
struct ClaudeUsageApp: App {
    @StateObject private var roster: RosterController
    @StateObject private var agent: UsageAgent

    init() {
        // Before the first roster read: a Keychain miss must fail quietly, never show a dialog.
        RosterSessionStore.disableKeychainDialogs()
        let roster = RosterController()
        _roster = StateObject(wrappedValue: roster)
        _agent = StateObject(wrappedValue: UsageAgent(roster: roster))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(agent: agent, creditsGate: agent.creditsGate)
        } label: {
            // The signed-in Claude Code account only. Extra subscriptions live in the Claude Accounts widget.
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text(agent.menuBarText).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Subscriptions", id: "accounts") {
            AccountsWindow(roster: roster)
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class UsageAgent: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    let creditsGate = UserDefaultsCreditsFetchGate()
    /// Extra subscriptions. Refreshed after the CLI snapshot is saved. Its errors do not touch that snapshot.
    let roster: RosterController

    /// Fixed cadence. WidgetKit also self-refreshes countdowns between writes.
    let refreshInterval: TimeInterval = 180
    private var timer: Timer?

    // Coalesce bursts (menu-open, widget button, timer) into at most one live fetch per interval.
    private var lastFetchAt = Date.distantPast
    private let minFetchInterval: TimeInterval = 20

    init(roster: RosterController) {
        self.roster = roster
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
        // Skip the subprocess when a fetch happened very recently; still repaint the widget so the
        // age (and any last data) render.
        if now.timeIntervalSince(lastFetchAt) < minFetchInterval {
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        isRefreshing = true
        lastFetchAt = now
        var snap = await UsageClient.fetchSnapshot(previous: snapshot)
        // Credits are supplemental. Only a fresh primary snapshot gets merged, and a miss never
        // changes the CLI pipeline's freshness or fixed error state.
        if !snap.stale {
            snap.credits = await CreditsClient.fetchCredits(gate: creditsGate)
        }
        try? SharedStore.save(snap)
        snapshot = snap
        notifyThresholds(for: snap)
        // Repaint Current sub now. The roster reads each account over the network and must not
        // hold this snapshot back.
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.current)
        // The roster is a second pipeline. A miss must not mark this snapshot stale or change its error.
        await roster.refresh()
        isRefreshing = false
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.accounts)
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

    func setCreditsEnabled(_ enabled: Bool) {
        creditsGate.setEnabled(enabled)
        if enabled {
            // A deliberate re-enable clears the breaker and should get one immediate credits retry.
            lastFetchAt = .distantPast
            Task { await refresh() }
        } else if var current = snapshot {
            current.credits = nil
            try? SharedStore.save(current)
            snapshot = current
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// User preference and breaker persistence for the shared credits client. Absence of the disabled
/// key means opt-in; an auto-disable additionally carries one fixed, non-sensitive reason.
@MainActor
final class UserDefaultsCreditsFetchGate: ObservableObject, CreditsFetchGate {
    private static let disabledKey = "creditsFetchDisabled"
    private static let reasonKey = "creditsFetchDisabledReason"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var disableReason: CreditsDisableReason?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let disabled = defaults.bool(forKey: Self.disabledKey)
        isEnabled = !disabled
        disableReason = disabled
            ? defaults.string(forKey: Self.reasonKey).flatMap(CreditsDisableReason.init(rawValue:))
            : nil
    }

    private let defaults: UserDefaults

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        disableReason = nil
        defaults.set(!enabled, forKey: Self.disabledKey)
        defaults.removeObject(forKey: Self.reasonKey)
    }

    func disable(reason: CreditsDisableReason) {
        isEnabled = false
        disableReason = reason
        defaults.set(true, forKey: Self.disabledKey)
        defaults.set(reason.rawValue, forKey: Self.reasonKey)
    }
}

struct MenuContent: View {
    @ObservedObject var agent: UsageAgent
    @ObservedObject var creditsGate: UserDefaultsCreditsFetchGate
    @Environment(\.openWindow) private var openWindow
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
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Claude").font(.headline).foregroundStyle(ClaudeTheme.clay)
                        Text(s.planLabel).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if agent.isRefreshing {
                            ProgressView().controlSize(.small)
                        }
                    }
                    AccountEmailLine(email: s.email)
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

            Toggle("Show usage credits", isOn: Binding(
                get: { creditsGate.isEnabled },
                set: { agent.setCreditsEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            if let reason = creditsGate.disableReason {
                Text("Disabled — \(reason.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Turn Show usage credits back on to retry.")
            }

            Text("Runs in the background and updates every \(Int(agent.refreshInterval / 60)) min. Tap ↻ on the widget for an instant refresh.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open") { openAccounts() }
                    .help("Sign in to more subscriptions")
                Spacer()
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

    private func openAccounts() {
        AccountsWindowLaunch.requested = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openWindow(id: "accounts")
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
