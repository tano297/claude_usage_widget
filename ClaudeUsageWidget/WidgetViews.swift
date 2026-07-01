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
        VStack(alignment: .leading, spacing: 5) {
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
            if s.session == nil && s.weeklyAll == nil && (s.weeklyScoped?.isEmpty ?? true) && s.credits == nil {
                Spacer()
                Text(s.error ?? "No usage data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                // The widget canvas is a fixed height and cannot scroll, so per-model rows (Opus,
                // Fable, …) can overflow. Offer progressively denser layouts and let SwiftUI pick
                // the roomiest one that actually fits — dropping countdowns, then the freshness
                // line, before anything clips.
                ViewThatFits(in: .vertical) {
                    body(s, spacing: 8, showResets: true, showFreshness: true)
                    body(s, spacing: 5, showResets: true, showFreshness: true)
                    body(s, spacing: 4, showResets: false, showFreshness: true)
                    body(s, spacing: 3, showResets: false, showFreshness: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// One density variant: the limit list plus an optional freshness footer. No flexible spacer —
    /// its natural height must be measurable so `ViewThatFits` can compare variants.
    private func body(_ s: UsageSnapshot, spacing: CGFloat, showResets: Bool, showFreshness: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            UsageList(snapshot: s, now: entry.date, compact: true, spacing: spacing, showResets: showResets)
            if showFreshness {
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
        let candidates: [(String, LimitBar)] =
            [("Session", s.session), ("Weekly", s.weeklyAll)].compactMap { name, bar in bar.map { (name, $0) } }
            + (s.weeklyScoped ?? []).map { ($0.name, $0.bar) }
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
