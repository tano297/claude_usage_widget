import Foundation

// MARK: - Severity

/// Normalized limit severity. When a source does not supply a severity value, derive one from the
/// utilization percent so colors stay consistent.
public enum Severity: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case high
    case critical
    case unknown

    public init(apiValue: String?) {
        switch apiValue?.lowercased() {
        case "normal", "ok", "none":   self = .normal
        case "warning", "warn":        self = .warning
        case "high":                   self = .high
        case "critical", "exceeded", "reached": self = .critical
        default:                        self = .unknown
        }
    }

    /// Prefer a source-provided severity; otherwise bucket by percent.
    public static func from(percent: Double, apiValue: String?) -> Severity {
        if let apiValue, !apiValue.isEmpty {
            let s = Severity(apiValue: apiValue)
            if s != .unknown { return s }
        }
        switch percent {
        case ..<50:  return .normal
        case ..<90:  return .warning
        default:     return .critical
        }
    }
}

// MARK: - Model

/// A single limit bar (session, weekly-all, a model-scoped weekly window).
public struct LimitBar: Codable, Sendable, Equatable {
    public var percent: Double
    public var resetsAt: Date?
    public var severity: Severity

    public init(percent: Double, resetsAt: Date?, severity: Severity) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
    }
}

/// A model-scoped weekly limit — e.g. "Weekly · Opus", "Weekly · Fable". Claude's `/usage`
/// prose labels these rows with the model display name, so the UI need not hard-code one.
public struct ScopedLimit: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var bar: LimitBar
    public var id: String { name }

    public init(name: String, bar: LimitBar) {
        self.name = name
        self.bar = bar
    }
}

/// The "usage credits" / overage-spend panel (second screenshot).
public struct CreditsInfo: Codable, Sendable, Equatable {
    public var usedMinor: Int
    public var limitMinor: Int
    public var balanceMinor: Int?
    public var currency: String
    public var exponent: Int
    public var resetsAt: Date?

    public init(usedMinor: Int,
                limitMinor: Int,
                balanceMinor: Int? = nil,
                currency: String,
                exponent: Int,
                resetsAt: Date? = nil) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.balanceMinor = balanceMinor
        self.currency = currency
        self.exponent = exponent
        self.resetsAt = resetsAt
    }

    /// Fraction 0...1 of the monthly credit cap consumed (nil when there is no cap).
    public var fraction: Double? {
        guard limitMinor > 0 else { return nil }
        return min(1.0, Double(usedMinor) / Double(limitMinor))
    }
}

/// Everything the widget renders. Written to Application Support by the agent and read there by
/// the widget through its read-only path exception.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var fetchedAt: Date
    public var planLabel: String
    /// Account metadata from `claude auth status`. Optional so snapshots written before the email
    /// field was introduced remain Codable-compatible.
    public var email: String?
    public var session: LimitBar?
    public var weeklyAll: LimitBar?
    /// Per-model weekly limits (Opus, Fable, …). Optional so snapshots written by older versions,
    /// which lack this key, still decode (as `nil`) instead of forcing a "no data" refetch.
    public var weeklyScoped: [ScopedLimit]?
    public var credits: CreditsInfo?
    public var stale: Bool
    public var error: String?

    public init(fetchedAt: Date,
                planLabel: String,
                email: String? = nil,
                session: LimitBar?,
                weeklyAll: LimitBar?,
                weeklyScoped: [ScopedLimit]?,
                credits: CreditsInfo?,
                stale: Bool,
                error: String?) {
        self.fetchedAt = fetchedAt
        self.planLabel = planLabel
        self.email = email
        self.session = session
        self.weeklyAll = weeklyAll
        self.weeklyScoped = weeklyScoped
        self.credits = credits
        self.stale = stale
        self.error = error
    }

    /// An explicit "no data yet" state — the widget shows this (a clear message) instead of
    /// fabricated placeholder numbers when there's no snapshot on disk (first run, agent not
    /// running, unreadable file). `stale` is true and every limit is nil.
    public static func noData(now: Date = Date(),
                              error: String = "Waiting for first update — is Claude Usage running?") -> UsageSnapshot {
        UsageSnapshot(fetchedAt: now, planLabel: "Claude",
                      session: nil, weeklyAll: nil, weeklyScoped: nil, credits: nil,
                      stale: true, error: error)
    }

    /// Fake but representative data — used ONLY for the WidgetKit gallery/preview, never as a
    /// stand-in for real usage (that would fabricate numbers).
    public static func placeholder(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: now,
            planLabel: "Max",
            email: "user@example.com",
            session: LimitBar(percent: 0, resetsAt: now.addingTimeInterval(4 * 3600 + 53 * 60), severity: .normal),
            weeklyAll: LimitBar(percent: 81, resetsAt: now.addingTimeInterval(23 * 60), severity: .warning),
            weeklyScoped: nil,
            credits: CreditsInfo(usedMinor: 0, limitMinor: 30000, balanceMinor: nil, currency: "USD", exponent: 2, resetsAt: firstOfNextMonth(after: now)),
            stale: false,
            error: nil
        )
    }
}

// MARK: - Plan label

/// Human label for the plan reported by `claude auth status --json`.
public func planLabel(subscriptionType: String?) -> String {
    guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return "Claude" }
    switch raw.lowercased() {
    case "max":        return "Max"
    case "pro":        return "Pro"
    case "team":       return "Team"
    case "free":       return "Free"
    case "enterprise": return "Enterprise"
    default:            return raw.capitalized
    }
}
