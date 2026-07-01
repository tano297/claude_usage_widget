import SwiftUI

// Reusable pieces shared by the menu bar popover and the Notification Center widget.

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

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                Spacer(minLength: 4)
                if bar.severity.showsWarningGlyph {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(bar.severity.color)
                }
                Text(percentString(bar.percent))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(bar.severity.color)
                    .monospacedDigit()
            }
            ProgressBarView(fraction: bar.percent / 100, color: bar.severity.color)
                .frame(height: compact ? 5 : 6)
            if let reset = bar.resetsAt {
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

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            if let s = snapshot.session { LimitRow(title: "Session", bar: s, now: now, compact: compact) }
            if let w = snapshot.weeklyAll { LimitRow(title: "Weekly", bar: w, now: now, compact: compact) }
            if let o = snapshot.weeklyOpus { LimitRow(title: "Weekly · Opus", bar: o, now: now, compact: compact) }
            if let c = snapshot.credits { CreditsRow(credits: c, now: now, compact: compact) }
        }
    }
}

/// A percentage ring for the small widget.
struct UsageRing: View {
    let percent: Double
    let severity: Severity
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(severity.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentString(percent))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
        }
    }
}
