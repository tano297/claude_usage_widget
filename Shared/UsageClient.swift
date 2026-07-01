import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Raw API shape (https://api.anthropic.com/api/oauth/usage)

enum RawUsage {
    struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Money: Decodable {
            let amount_minor: Int?
            let currency: String?
            let exponent: Int?
        }
        struct Spend: Decodable {
            let used: Money?
            let limit: Money?
            let percent: Double?
            let severity: String?
            let enabled: Bool?
            let balance: Money?
        }
        struct ExtraUsage: Decodable {
            let is_enabled: Bool?
            let monthly_limit: Int?
            let used_credits: Double?
            let currency: String?
            let decimal_places: Int?
        }
        struct LimitEntry: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let severity: String?
            let resets_at: String?
            let is_active: Bool?
        }

        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let extra_usage: ExtraUsage?
        let spend: Spend?
        let limits: [LimitEntry]?
    }
}

// MARK: - Parser (pure; unit-tested against fixtures)

public enum UsageParser {
    public static func parse(_ data: Data,
                             planLabel: String,
                             now: Date,
                             fetchedAt: Date) throws -> UsageSnapshot {
        let raw = try JSONDecoder().decode(RawUsage.Response.self, from: data)

        func entry(_ kinds: Set<String>) -> RawUsage.Response.LimitEntry? {
            raw.limits?.first { e in
                guard let k = e.kind?.lowercased() else { return false }
                return kinds.contains(k)
            }
        }

        func bar(window: RawUsage.Response.Window?, kinds: Set<String>) -> LimitBar? {
            let match = entry(kinds)
            // Prefer the typed window; fall back to the normalized limits[] array.
            if let window, let u = window.utilization {
                let resets = parseISODate(window.resets_at) ?? parseISODate(match?.resets_at)
                return LimitBar(percent: u, resetsAt: resets, severity: .from(percent: u, apiValue: match?.severity))
            }
            if let match, let p = match.percent {
                return LimitBar(percent: p, resetsAt: parseISODate(match.resets_at), severity: .from(percent: p, apiValue: match.severity))
            }
            return nil
        }

        let session = bar(window: raw.five_hour, kinds: ["session"])
        let weeklyAll = bar(window: raw.seven_day, kinds: ["weekly_all", "weekly"])
        let weeklyOpus = bar(window: raw.seven_day_opus, kinds: ["weekly_opus", "opus"])
        let credits = makeCredits(raw: raw, now: now)

        return UsageSnapshot(fetchedAt: fetchedAt,
                             planLabel: planLabel,
                             session: session,
                             weeklyAll: weeklyAll,
                             weeklyOpus: weeklyOpus,
                             credits: credits,
                             stale: false,
                             error: nil)
    }

    /// Prefer the richer `spend` block; fall back to `extra_usage`. Only surfaces when enabled.
    static func makeCredits(raw: RawUsage.Response, now: Date) -> CreditsInfo? {
        if let spend = raw.spend, spend.enabled == true {
            let used = spend.used?.amount_minor ?? 0
            let limit = spend.limit?.amount_minor ?? 0
            guard limit > 0 || used > 0 else { return nil }
            let currency = spend.limit?.currency ?? spend.used?.currency ?? "USD"
            let exponent = spend.limit?.exponent ?? spend.used?.exponent ?? 2
            return CreditsInfo(usedMinor: used,
                               limitMinor: limit,
                               balanceMinor: spend.balance?.amount_minor,
                               currency: currency,
                               exponent: exponent,
                               resetsAt: firstOfNextMonth(after: now))
        }
        if let ex = raw.extra_usage, ex.is_enabled == true, let limit = ex.monthly_limit, limit > 0 {
            let exponent = ex.decimal_places ?? 2
            // `used_credits` is a major-unit amount; scale to minor units to match the cap.
            let usedMinor = Int(((ex.used_credits ?? 0) * pow(10.0, Double(exponent))).rounded())
            return CreditsInfo(usedMinor: usedMinor,
                               limitMinor: limit,
                               balanceMinor: nil,
                               currency: ex.currency ?? "USD",
                               exponent: exponent,
                               resetsAt: firstOfNextMonth(after: now))
        }
        return nil
    }
}

// MARK: - Keychain credentials

public struct ClaudeCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let rateLimitTier: String?
    public let subscriptionType: String?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// True if the token is expired or expires within `seconds`.
    public func expiresSoon(within seconds: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date().addingTimeInterval(seconds)
    }
}

/// Read Claude Code's OAuth credentials from the login Keychain (service "Claude Code-credentials").
/// Triggers a one-time "Always Allow" prompt for a non-sandboxed process.
public func readClaudeCredentials() -> ClaudeCredentials? {
    #if canImport(Security)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }

    struct Blob: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
        }
        let claudeAiOauth: OAuth
    }
    guard let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return nil }
    let expires = blob.claudeAiOauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    return ClaudeCredentials(accessToken: blob.claudeAiOauth.accessToken,
                             refreshToken: blob.claudeAiOauth.refreshToken,
                             expiresAt: expires,
                             rateLimitTier: blob.claudeAiOauth.rateLimitTier,
                             subscriptionType: blob.claudeAiOauth.subscriptionType)
    #else
    return nil
    #endif
}

// MARK: - Live fetch

public enum UsageClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The `/usage` endpoint requires a `claude-code/<version>` User-Agent or it 429s.
    static let cachedUserAgent: String = {
        let fallback = "claude-code/2.1.0"
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                return "claude-code/\(text[r])"
            }
        } catch {}
        #endif
        return fallback
    }()

    private enum RequestResult { case success(Data); case http(Int); case failure(String) }

    private static func performRequest(accessToken: String) async -> RequestResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(cachedUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure("Bad response from server.") }
            guard http.statusCode == 200 else { return .http(http.statusCode) }
            return .success(data)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Fetch + parse. Pass `using` a cached credential to avoid a Keychain read on every call.
    /// This client is deliberately read-only with respect to Claude Code credentials: it never
    /// refreshes, rewrites, or deletes the Keychain item. On any failure, reuses the last good
    /// snapshot marked stale.
    public static func fetchSnapshot(now: Date = Date(),
                                     using provided: ClaudeCredentials? = nil) async -> (snapshot: UsageSnapshot, creds: ClaudeCredentials?) {
        guard let creds = provided ?? readClaudeCredentials() else {
            let s = UsageSnapshot(fetchedAt: now, planLabel: "Claude",
                                  session: nil, weeklyAll: nil, weeklyOpus: nil, credits: nil,
                                  stale: true,
                                  error: "No Claude Code credentials found. Sign in with `claude`.")
            return (s, nil)
        }
        let label = planLabel(rateLimitTier: creds.rateLimitTier, subscriptionType: creds.subscriptionType)

        let result = await performRequest(accessToken: creds.accessToken)

        let snapshot: UsageSnapshot
        switch result {
        case .success(let data):
            snapshot = (try? UsageParser.parse(data, planLabel: label, now: now, fetchedAt: now))
                ?? degraded(now: now, label: label, error: "Could not parse usage response.")
        case .http(let code):
            let msg = code == 401 ? "Token expired — open Claude Code to refresh." : "HTTP \(code)"
            snapshot = degraded(now: now, label: label, error: msg)
        case .failure(let msg):
            snapshot = degraded(now: now, label: label, error: msg)
        }
        return (snapshot, creds)
    }

    /// Last-known snapshot marked stale, or an empty stale snapshot if none exists.
    static func degraded(now: Date, label: String, error: String) -> UsageSnapshot {
        if var last = SharedStore.load() {
            last.stale = true
            last.error = error
            last.planLabel = label
            return last
        }
        return UsageSnapshot(fetchedAt: now, planLabel: label,
                             session: nil, weeklyAll: nil, weeklyOpus: nil, credits: nil,
                             stale: true, error: error)
    }
}
