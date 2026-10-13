import SwiftUI

// Reusable pieces shared by the menu bar popover and the Notification Center widget.

/// Account email shown only on surfaces with enough horizontal room. Long addresses preserve both
/// the local-part prefix and domain through middle truncation.
struct AccountEmailLine: View {
    let email: String?
    var font: Font = .caption

    var body: some View {
        if let email, !email.isEmpty {
            Text(email)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A rounded track + fill progress bar.
struct ProgressBarView: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// One labelled limit row: title + % + warning glyph, a bar, and a reset countdown.
struct LimitRow: View {
    let title: String
    let bar: LimitBar
    let now: Date
    var compact: Bool = false
    /// The widget hides the per-row countdown in its densest layouts to avoid clipping.
    var showReset: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if bar.severity.showsWarningGlyph {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(usagePercentColor(bar.percent))
                }
                Text(percentString(bar.percent))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(usagePercentColor(bar.percent))
                    .monospacedDigit()
            }
            ProgressBarView(fraction: bar.percent / 100, color: usagePercentColor(bar.percent))
                .frame(height: compact ? 5 : 6)
            if showReset, let reset = bar.resetsAt {
                Text("resets in \(countdownString(to: reset, from: now))")
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The usage-credits / spend line.
struct CreditsRow: View {
    let credits: CreditsInfo
    let now: Date
    var compact: Bool = false

    var body: some View {
        let used = moneyString(minor: credits.usedMinor, exponent: credits.exponent, currency: credits.currency)
        let cap = moneyString(minor: credits.limitMinor, exponent: credits.exponent, currency: credits.currency)
        HStack(spacing: 4) {
            Text("Credits").font(.system(size: compact ? 11 : 12, weight: .medium))
            Spacer(minLength: 4)
            Text("\(used) / \(cap)")
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Stacked list of every relevant limit — the core of both surfaces. Null sections are skipped.
struct UsageList: View {
    let snapshot: UsageSnapshot
    let now: Date
    var compact: Bool = false
    /// Overrides for the widget's density-adaptive layout; the popover uses the defaults.
    var spacing: CGFloat? = nil
    var showResets: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: spacing ?? (compact ? 7 : 10)) {
            if let s = snapshot.session { LimitRow(title: "Session", bar: s, now: now, compact: compact, showReset: showResets) }
            if let w = snapshot.weeklyAll { LimitRow(title: "Weekly", bar: w, now: now, compact: compact, showReset: showResets) }
            ForEach(snapshot.weeklyScoped ?? []) { scoped in
                LimitRow(title: "Weekly · \(scoped.name)", bar: scoped.bar, now: now, compact: compact, showReset: showResets)
            }
            if let c = snapshot.credits { CreditsRow(credits: c, now: now, compact: compact) }
        }
    }
}

/// "Updated 12 sec ago" (green) or "Stale · 9 min ago" (orange). Shared by the menu and widget.
/// Uses `Text(date, style: .relative)`, which auto-ticks every second in both widgets and normal
/// views — no timeline reloads needed, so the age never looks frozen or jumpy.
struct FreshnessRow: View {
    let snapshot: UsageSnapshot
    var dotSize: CGFloat = 7
    var font: Font = .caption2

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snapshot.stale ? Color.orange : Color.green)
                .frame(width: dotSize, height: dotSize)
            (Text(snapshot.stale ? "Stale · " : "Updated ")
             + Text(snapshot.fetchedAt, style: .relative))
                .foregroundStyle(snapshot.stale ? Color.orange : Color.secondary)
        }
        .font(font)
    }
}

/// Age of one roster reading: "Updated 12 sec ago" or "Stale · 3 min ago".
/// A plain string, not `Text(date, style: .relative)`. Several live relative dates in one widget
/// make the desktop snapshot render black.
struct ReadingAge: View {
    let fetchedAt: Date?
    var now: Date
    var stale: Bool = false
    var font: Font = .system(size: 10)

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stale ? Color.orange : Color.green)
                .frame(width: 5, height: 5)
            Text(label)
                .font(font)
                .foregroundStyle(stale ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
    }

    private var label: String {
        guard let fetchedAt else { return "—" }
        let age = readingAgeString(from: fetchedAt, to: now)
        return stale ? "Stale · \(age)" : "Updated \(age)"
    }
}

/// A percentage ring for the small widget.
struct UsageRing: View {
    let percent: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(usagePercentColor(percent), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentString(percent))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
        }
    }
}
