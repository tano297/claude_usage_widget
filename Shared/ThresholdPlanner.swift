import Foundation

// MARK: - Threshold notifications (pure logic)

/// Decides which "usage crossed a threshold" notifications to send for a snapshot: every 10%
/// (10…100) per limit window, and every $10 of credits spent. Pure and side-effect free — the
/// app feeds it the previous per-window state and posts whatever comes back — so the crossing
/// rules are covered by DataLayerCheck. State per key:

public struct ThresholdKeyState: Codable, Equatable, Sendable {
    /// Percent windows: floor(percent / 10), capped at 10. Credits: floor(spent / $10).
    public var bucket: Int
    /// Cycle marker — when a window's reset time moves, the window restarted and the bucket
    /// baseline must be reseeded silently instead of re-announcing low thresholds.
    public var resetsAt: Date?

    public init(bucket: Int, resetsAt: Date?) {
        self.bucket = bucket
        self.resetsAt = resetsAt
    }
}

public struct ThresholdAlert: Equatable, Sendable {
    public var key: String    // "session" | "weekly" | "scoped:<name>" | "credits"
    public var title: String  // "Weekly · Fable at 80%" / "Session limit reached" / "Credits: $50.00 spent"
    public var body: String   // "resets in 5d 13h" / "$300.00 limit · resets Aug 1"; may be empty
    public var bucket: Int    // with `key`, forms a stable notification identifier
}

public enum ThresholdPlanner {

    /// Reset times can drift by a little between polls (server-side recomputation) and lose
    /// sub-second precision through the ISO-8601 round trip; only a move bigger than this is a
    /// genuine new cycle.
    static let resetTolerance: TimeInterval = 60

    /// Credits notify every this many major currency units spent ($10).
    public static let creditsStepMajor = 10

    /// Compare a snapshot against the previously stored state.
    /// Returns the alerts to post (at most one per window — a multi-bucket jump announces only
    /// the highest threshold) and the replacement state (keys absent from the snapshot are
    /// pruned; new keys are seeded silently so a fresh install doesn't blast one alert per
    /// already-consumed window).
    public static func plan(snapshot: UsageSnapshot,
                            state: [String: ThresholdKeyState],
                            now: Date)
        -> (alerts: [ThresholdAlert], state: [String: ThresholdKeyState]) {
        // Error/stale snapshots carry old numbers — never alert (or advance state) from them.
        guard !snapshot.stale else { return ([], state) }

        var alerts: [ThresholdAlert] = []
        var newState: [String: ThresholdKeyState] = [:]

        // Shared crossing rules: seed silently on first sight, reseed silently on a new cycle
        // (resetsAt moved) or a bucket drop (reset fallback), alert only on an upward crossing.
        func track(key: String, bucket: Int, resetsAt: Date?, makeAlert: (Int) -> ThresholdAlert) {
            newState[key] = ThresholdKeyState(bucket: bucket, resetsAt: resetsAt)
            guard let old = state[key] else { return }
            if let o = old.resetsAt, let n = resetsAt, abs(o.timeIntervalSince(n)) > resetTolerance { return }
            guard bucket > old.bucket else { return }
            alerts.append(makeAlert(bucket))
        }

        func percentWindow(key: String, name: String, bar: LimitBar?) {
            guard let bar else { return }
            let bucket = max(0, min(10, Int(bar.percent / 10)))
            track(key: key, bucket: bucket, resetsAt: bar.resetsAt) { b in
                ThresholdAlert(
                    key: key,
                    title: b >= 10 ? "\(name) limit reached" : "\(name) at \(b * 10)%",
                    body: bar.resetsAt.map { "resets in \(countdownString(to: $0, from: now))" } ?? "",
                    bucket: b)
            }
        }

        percentWindow(key: "session", name: "Session", bar: snapshot.session)
        percentWindow(key: "weekly", name: "Weekly", bar: snapshot.weeklyAll)
        for scoped in snapshot.weeklyScoped ?? [] {
            percentWindow(key: "scoped:\(scoped.name)", name: "Weekly · \(scoped.name)", bar: scoped.bar)
        }

        if let c = snapshot.credits {
            let stepMinor = creditsStepMajor * Int(pow(10.0, Double(c.exponent)))
            let bucket = stepMinor > 0 ? max(0, c.usedMinor / stepMinor) : 0
            track(key: "credits", bucket: bucket, resetsAt: c.resetsAt) { b in
                var body = "\(moneyString(minor: c.limitMinor, exponent: c.exponent, currency: c.currency)) limit"
                if let r = c.resetsAt { body += " · resets \(shortDateString(r))" }
                return ThresholdAlert(
                    key: "credits",
                    title: "Credits: \(moneyString(minor: b * stepMinor, exponent: c.exponent, currency: c.currency)) spent",
                    body: body,
                    bucket: b)
            }
        }

        return (alerts, newState)
    }

    // MARK: State persistence

    // The state is stored in UserDefaults as a JSON *string* (ISO-8601 dates) so it stays
    // readable and pokeable with `defaults read/write` when testing crossings by hand.

    public static func encodeState(_ state: [String: ThresholdKeyState]) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(state) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decodeState(_ json: String?) -> [String: ThresholdKeyState] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: ThresholdKeyState].self, from: data)) ?? [:]
    }
}
