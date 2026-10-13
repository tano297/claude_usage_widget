import Foundation

// MARK: - Roster

/// One signed-in subscription, as the widget is allowed to see it. The refresh token that produced
/// these meters never enters this type.
public struct RosterAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var email: String
    public var fiveHour: LimitBar?
    public var week: LimitBar?
    public var fetchedAt: Date?
    public var stale: Bool
    public var error: String?

    public init(id: UUID = UUID(),
                email: String,
                fiveHour: LimitBar? = nil,
                week: LimitBar? = nil,
                fetchedAt: Date? = nil,
                stale: Bool = false,
                error: String? = nil) {
        self.id = id
        self.email = email
        self.fiveHour = fiveHour
        self.week = week
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.error = error
    }
}

/// The account list the agent writes and the widget reads. Separate from `usage.json`, which stays
/// the Claude CLI snapshot for the subscription currently signed in on this Mac.
public struct RosterSnapshot: Codable, Sendable, Equatable {
    public var accounts: [RosterAccount]

    public init(accounts: [RosterAccount]) {
        self.accounts = accounts
    }

    public static let empty = RosterSnapshot(accounts: [])
}

// MARK: - Usage response

/// Decode the OAuth usage payload down to the two windows the roster line shows.
///
/// The newer payload lists windows in `limits` (`session`, `weekly_all`). Older payloads use
/// `five_hour` and `seven_day`. A window present in either place is kept. Unknown keys are ignored.
public enum RosterUsageParser {
    public static func parse(_ data: Data) throws -> (fiveHour: LimitBar?, week: LimitBar?) {
        let raw: RawUsage
        do {
            raw = try JSONDecoder().decode(RawUsage.self, from: data)
        } catch {
            throw RosterParseError.unreadable
        }

        var fiveHour = raw.fiveHour.map(bar(fromLegacy:))
        var week = raw.sevenDay.map(bar(fromLegacy:))
        // `limits` is the newer shape. When a window is present there, it wins over the legacy field.
        for entry in raw.limits ?? [] {
            guard let percent = entry.percent else { continue }
            let parsed = LimitBar(percent: percent,
                                  resetsAt: parseISODate(entry.resetsAt),
                                  severity: .from(percent: percent, apiValue: entry.severity))
            switch entry.kind {
            case "session", "five_hour":
                fiveHour = parsed
            case "weekly_all", "seven_day", "weekly":
                week = parsed
            default:
                break
            }
        }
        guard fiveHour != nil || week != nil else { throw RosterParseError.noLimits }
        return (fiveHour, week)
    }

    private static func bar(fromLegacy limit: RawLimit) -> LimitBar {
        LimitBar(percent: limit.utilization,
                 resetsAt: parseISODate(limit.resetsAt),
                 severity: .from(percent: limit.utilization, apiValue: nil))
    }
}

public enum RosterParseError: Error, Equatable {
    case unreadable
    case noLimits
}

private struct RawUsage: Decodable {
    let fiveHour: RawLimit?
    let sevenDay: RawLimit?
    let limits: [RawLimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

private struct RawLimit: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct RawLimitEntry: Decodable {
    let kind: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case severity
        case resetsAt = "resets_at"
    }
}

// MARK: - Line text

/// Weekday and clock, for example "Fri 3:00 AM". The template follows the 12/24-hour setting.
public func resetClockString(_ date: Date,
                             locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.timeZone = timeZone
    fmt.setLocalizedDateFormatFromTemplate("EEEjm")
    return fmt.string(from: date)
        .replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

/// The part of the address that fits a menu-bar chip. The full address stays on the line below.
public func rosterShortName(_ email: String, limit: Int = 12) -> String {
    let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
    let trimmed = local.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > limit else { return trimmed.isEmpty ? email : trimmed }
    return String(trimmed.prefix(limit))
}

/// Compact readout: `ada 4% 4h 52m · 89% 3d 4h`.
/// The first pair is the 5-hour window. The second pair is the weekly window.
public func rosterStatusText(_ accounts: [RosterAccount], now: Date = Date()) -> String {
    guard !accounts.isEmpty else { return "" }
    return accounts.map { account in
        "\(rosterShortName(account.email)) \(rosterMeter(account.fiveHour, now: now)) · \(rosterMeter(account.week, now: now))"
    }.joined(separator: "  ")
}

/// Soonest weekly reset first. An account with no weekly reset goes last.
public func rosterByWeeklyReset(_ accounts: [RosterAccount]) -> [RosterAccount] {
    accounts.sorted { a, b in
        switch (a.week?.resetsAt, b.week?.resetsAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
        }
    }
}

/// `12% 3h 20m`, or an em dash when that window was not in the payload.
public func rosterMeter(_ bar: LimitBar?, now: Date) -> String {
    guard let bar else { return "—" }
    let left = bar.resetsAt.map { countdownString(to: $0, from: now) } ?? "—"
    return "\(Int(bar.percent.rounded()))% \(left)"
}
