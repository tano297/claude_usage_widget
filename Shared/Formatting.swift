import Foundation

// MARK: - Date parsing

/// Parse the API's ISO-8601 timestamps, which carry microsecond fractional seconds and an
/// explicit offset (e.g. "2026-07-01T20:30:00.577840+00:00"). Tries fractional first, then
/// plain, then strips an arbitrary-precision fraction as a last resort.
public func parseISODate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }

    // Microsecond precision can defeat .withFractionalSeconds; drop the fraction and retry.
    if let dot = s.range(of: #"\.\d+"#, options: .regularExpression) {
        var stripped = s
        stripped.removeSubrange(dot)
        if let d = plain.date(from: stripped) { return d }
    }
    return nil
}

// MARK: - Countdown

/// "resets in" body: "4h 53m", "23m", "2d 4h", or "now".
public func countdownString(to date: Date, from now: Date) -> String {
    let secs = Int(date.timeIntervalSince(now))
    if secs <= 0 { return "now" }
    let days = secs / 86_400
    let hours = (secs % 86_400) / 3_600
    let mins = (secs % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// MARK: - Numbers & money

public func percentString(_ p: Double) -> String {
    "\(Int(p.rounded()))%"
}

/// Format minor currency units (e.g. 30000, exp 2, USD) as "$300.00".
public func moneyString(minor: Int, exponent: Int, currency: String) -> String {
    let value = Double(minor) / pow(10.0, Double(exponent))
    let fmt = NumberFormatter()
    fmt.numberStyle = .currency
    fmt.currencyCode = currency
    fmt.minimumFractionDigits = min(2, exponent)
    fmt.maximumFractionDigits = max(2, exponent)
    return fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
}

// MARK: - Reset dates

/// First day of the month following `date` (used for the monthly credits reset, e.g. "Aug 1").
public func firstOfNextMonth(after date: Date, calendar: Calendar = .current) -> Date {
    var comps = calendar.dateComponents([.year, .month], from: date)
    comps.month = (comps.month ?? 1) + 1
    comps.day = 1
    comps.hour = 0
    comps.minute = 0
    comps.second = 0
    return calendar.date(from: comps) ?? date
}

/// "Aug 1" style short date for the credits reset line.
public func shortDateString(_ date: Date, calendar: Calendar = .current) -> String {
    let fmt = DateFormatter()
    fmt.calendar = calendar
    fmt.locale = Locale.current
    fmt.setLocalizedDateFormatFromTemplate("MMMd")
    return fmt.string(from: date)
}
