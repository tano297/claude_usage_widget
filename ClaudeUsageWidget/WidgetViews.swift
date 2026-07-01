import WidgetKit
import SwiftUI

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(entry: entry)
        default:           MediumUsageView(entry: entry)
        }
    }
}

struct MediumUsageView: View {
    let entry: UsageEntry
    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude").font(.system(size: 13, weight: .bold))
                Text(s.planLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(intent: RefreshUsageIntent()) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if s.session == nil && s.weeklyAll == nil && s.weeklyOpus == nil && s.credits == nil {
                Spacer()
                Text(s.error ?? "No usage data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                UsageList(snapshot: s, now: entry.date, compact: true)
                Spacer(minLength: 0)
                FreshnessRow(snapshot: s, dotSize: 6, font: .system(size: 9))
            }
        }
    }
}

struct SmallUsageView: View {
    let entry: UsageEntry
    var body: some View {
        let s = entry.snapshot
        // Most-consumed limit gets the ring.
        let candidates: [(String, LimitBar)] = [
            ("Session", s.session),
            ("Weekly", s.weeklyAll),
            ("Opus", s.weeklyOpus),
        ].compactMap { name, bar in bar.map { (name, $0) } }
        let top = candidates.max(by: { $0.1.percent < $1.1.percent })

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(s.planLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(intent: RefreshUsageIntent()) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let top {
                UsageRing(percent: top.1.percent, severity: top.1.severity)
                    .frame(width: 58, height: 58)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("\(top.0) · \(top.1.resetsAt.map { countdownString(to: $0, from: entry.date) } ?? "—")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                FreshnessRow(snapshot: s, dotSize: 5, font: .system(size: 8))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Spacer()
                Text(s.error ?? "No data")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
    }
}
