import WidgetKit
import SwiftUI

struct AccountsEntry: TimelineEntry {
    let date: Date
    let roster: RosterSnapshot
}

/// Extra subscriptions only. The Claude Usage widget keeps the account signed in to `claude`.
struct AccountsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AccountsEntry {
        AccountsEntry(date: Date(), roster: Self.sample(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (AccountsEntry) -> Void) {
        let roster = context.isPreview ? Self.sample(now: Date()) : RosterStore.load()
        completion(AccountsEntry(date: Date(), roster: roster))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccountsEntry>) -> Void) {
        let roster = RosterStore.load()
        let now = Date()
        // The age is a plain string, so the timeline has to move it forward: every 15 seconds for
        // the first two minutes, then every minute for an hour. The agent reloads this widget after
        // each roster refresh. When macOS defers a reload, the age still keeps moving.
        var offsets: [TimeInterval] = stride(from: 0, to: 120, by: 15).map { $0 }
        offsets += stride(from: 120, through: 3600, by: 60).map { $0 }
        let entries = offsets.map { AccountsEntry(date: now.addingTimeInterval($0), roster: roster) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }

    /// Gallery only. Real meters come from roster.json.
    private static func sample(now: Date) -> RosterSnapshot {
        RosterSnapshot(accounts: [
            RosterAccount(email: "later@example.com",
                          fiveHour: LimitBar(percent: 4, resetsAt: now.addingTimeInterval(4 * 3600 + 60), severity: .normal),
                          week: LimitBar(percent: 80, resetsAt: now.addingTimeInterval(3 * 86_400), severity: .warning),
                          fetchedAt: now.addingTimeInterval(-45)),
            RosterAccount(email: "soon@example.com",
                          fiveHour: LimitBar(percent: 12, resetsAt: now.addingTimeInterval(90 * 60), severity: .normal),
                          week: LimitBar(percent: 40, resetsAt: now.addingTimeInterval(5 * 3600), severity: .normal),
                          fetchedAt: now.addingTimeInterval(-3 * 60)),
            RosterAccount(email: "mid@example.com",
                          fiveHour: nil,
                          week: LimitBar(percent: 10, resetsAt: now.addingTimeInterval(26 * 3600), severity: .normal),
                          fetchedAt: now.addingTimeInterval(-12 * 60),
                          stale: true,
                          error: "Sign in again.")
        ])
    }
}

struct ClaudeAccountsWidget: Widget {
    let kind = WidgetKind.accounts

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccountsProvider()) { entry in
            AccountsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("All subs")
        .description("Every signed-in subscription, soonest weekly reset first. Use the large size under Current sub.")
        .supportedFamilies([.systemLarge])
    }
}

struct AccountsWidgetView: View {
    let entry: AccountsEntry

    private var accounts: [RosterAccount] {
        rosterByWeeklyReset(entry.roster.accounts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("All subs")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ClaudeTheme.clay)
                Spacer(minLength: 4)
                Button(intent: RefreshUsageIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            if accounts.isEmpty {
                Spacer()
                Text("No accounts yet. Choose Open in the menu, then Add account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            Divider().padding(.vertical, 4)
                        }
                        AccountBlock(account: account, now: entry.date)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// One subscription on two lines: the address, then both meters. The week meter keeps the weekday and clock.
private struct AccountBlock: View {
    let account: RosterAccount
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(account.email)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = account.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                ReadingAge(fetchedAt: account.fetchedAt, now: now, stale: account.stale)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                meter(title: "5h",
                      percent: account.fiveHour?.percent,
                      detail: account.fiveHour?.resetsAt.map { hourMinuteString(to: $0, from: now) } ?? "—")
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    meter(title: "Week",
                          percent: account.week?.percent,
                          detail: account.week?.resetsAt.map { countdownString(to: $0, from: now) } ?? "—")
                    Text(account.week?.resetsAt.map { resetClockString($0) } ?? "—")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
    }

    private func meter(title: String, percent: Double?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(percent.map { percentString($0) } ?? "—")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent.map { usagePercentColor($0) } ?? .secondary)
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
