import Foundation
import ClaudeUsageCore

// Lightweight assertion harness — no XCTest, so it runs with Command Line Tools alone.
var failures = 0
func check(_ cond: Bool, _ msg: String, line: UInt = #line) {
    if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg)  (line \(line))") }
}
func eq<T: Equatable>(_ a: T?, _ b: T, _ msg: String, line: UInt = #line) {
    check(a == b, "\(msg)  [\(String(describing: a)) == \(b)]", line: line)
}

// Live mode: exercise the real app pipeline (Keychain read -> network -> parse).
if CommandLine.arguments.contains("--live") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let (s, _, _) = await UsageClient.fetchSnapshot()
        print("LIVE snapshot — plan: \(s.planLabel)\(s.stale ? "  [STALE]" : "")")
        if let e = s.error { print("  error: \(e)") }
        func line(_ name: String, _ b: LimitBar?) {
            guard let b else { return }
            let reset = b.resetsAt.map { "resets in " + countdownString(to: $0, from: Date()) } ?? "—"
            print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(percentString(b.percent))  · \(reset)  [\(b.severity)]")
        }
        line("Session", s.session)
        line("Weekly", s.weeklyAll)
        for scoped in s.weeklyScoped ?? [] { line("Weekly·\(scoped.name)", scoped.bar) }
        if let c = s.credits {
            let used = moneyString(minor: c.usedMinor, exponent: c.exponent, currency: c.currency)
            let cap = moneyString(minor: c.limitMinor, exponent: c.exponent, currency: c.currency)
            print("  Credits    \(used) / \(cap)" + (c.resetsAt.map { " · resets " + shortDateString($0) } ?? ""))
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // DataLayerCheck
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // repo root
func fixture(_ name: String) -> Data {
    try! Data(contentsOf: repoRoot.appendingPathComponent("fixtures/\(name).json"))
}
let now = parseISODate("2026-07-01T15:00:00Z")!
func parse(_ name: String, _ label: String = "Max (20x)") -> UsageSnapshot {
    try! UsageParser.parse(fixture(name), planLabel: label, now: now, fetchedAt: now)
}

print("max20x (matches screenshot 1 & 2):")
let m = parse("max20x")
eq(m.session?.percent, 0, "session 0%")
eq(m.session?.severity, .normal, "session normal")
eq(m.weeklyAll?.percent, 81, "weekly 81%")
eq(m.weeklyAll?.severity, .warning, "weekly warning")
check(m.weeklyScoped == nil, "no scoped weekly bars")
eq(m.credits?.usedMinor, 0, "credits used 0")
eq(m.credits?.limitMinor, 30000, "credits cap 30000 minor")
eq(moneyString(minor: m.credits!.limitMinor, exponent: m.credits!.exponent, currency: m.credits!.currency), "$300.00", "cap renders $300.00")
check(m.session?.resetsAt != nil, "microsecond ISO timestamp parses")

print("pro (no opus, no credits):")
let p = parse("pro", "Pro")
eq(p.session?.percent, 45, "session 45%")
eq(p.weeklyAll?.percent, 60, "weekly 60%")
check(p.weeklyScoped == nil, "no scoped weekly bars")
check(p.credits == nil, "credits disabled -> hidden")

print("max5x_opus (legacy opus window folds into scoped list + credits + balance):")
let x = parse("max5x_opus", "Max (5x)")
eq(x.session?.percent, 92, "session 92%")
eq(x.session?.severity, .critical, "session critical")
let xOpus = x.weeklyScoped?.first { $0.name == "Opus" }
eq(x.weeklyScoped?.count, 1, "one scoped bar")
eq(xOpus?.bar.percent, 95, "opus 95%")
eq(xOpus?.bar.severity, .critical, "opus critical")
eq(x.credits?.usedMinor, 4200, "credits used 4200 minor")
eq(x.credits?.balanceMinor, 25000, "balance 25000 minor")
eq(moneyString(minor: 4200, exponent: 2, currency: "USD"), "$42.00", "used renders $42.00")

print("weekly_scoped (new API shape — per-model weekly caps incl. Fable):")
let ws = parse("weekly_scoped")
eq(ws.session?.percent, 14, "session 14%")
eq(ws.weeklyAll?.percent, 3, "weekly 3%")
eq(ws.weeklyScoped?.count, 2, "two scoped model bars")
let fable = ws.weeklyScoped?.first { $0.name == "Fable" }
eq(fable?.bar.percent, 42, "Fable 42%")
eq(fable?.bar.severity, .warning, "Fable warning")
check(fable?.bar.resetsAt != nil, "Fable reset parsed")
let wsOpus = ws.weeklyScoped?.first { $0.name == "Opus" }
eq(wsOpus?.bar.percent, 88, "Opus 88%")
eq(wsOpus?.bar.severity, .high, "Opus high")

print("menu bar summary (all windows, labeled):")
eq(menuBarSummary(ws), "S14 W3 F42 O88", "scoped fixture -> S14 W3 F42 O88")
eq(menuBarSummary(m), "S0 W81", "max20x -> S0 W81 (no scoped)")
eq(menuBarSummary(nil), "—", "nil snapshot -> em dash")
eq(menuBarSummary(UsageSnapshot.noData(now: now)), "—", "noData (all-nil limits) -> em dash")
var collision = ws
collision.weeklyScoped = [ScopedLimit(name: "Sonnet", bar: LimitBar(percent: 45.6, resetsAt: nil, severity: .normal))]
eq(menuBarSummary(collision), "S14 W3 So46", "label collision -> two letters; 45.6 rounds to 46")

print("limits_only (typed windows absent -> fall back to limits[]):")
let l = parse("limits_only")
eq(l.session?.percent, 33, "session from limits 33%")
eq(l.weeklyAll?.percent, 88, "weekly from limits 88%")
eq(l.weeklyAll?.severity, .high, "weekly high")
check(l.session?.resetsAt != nil, "reset parsed from limits[]")

print("plan labels:")
eq(planLabel(rateLimitTier: "default_claude_max_20x", subscriptionType: "max"), "Max (20x)", "max_20x")
eq(planLabel(rateLimitTier: "default_claude_max_5x", subscriptionType: "max"), "Max (5x)", "max_5x")
eq(planLabel(rateLimitTier: "default_claude_pro", subscriptionType: "pro"), "Pro", "pro")
eq(planLabel(rateLimitTier: "default_claude_team", subscriptionType: nil), "Team", "unknown tier prettified")
eq(planLabel(rateLimitTier: nil, subscriptionType: "max"), "Max", "fallback to subscriptionType")
eq(planLabel(rateLimitTier: nil, subscriptionType: nil), "Claude", "final fallback")

print("severity derivation (API omits severity):")
eq(Severity.from(percent: 10, apiValue: nil), .normal, "10% normal")
eq(Severity.from(percent: 75, apiValue: nil), .warning, "75% warning")
eq(Severity.from(percent: 96, apiValue: nil), .critical, "96% critical")
eq(Severity.from(percent: 5, apiValue: "warning"), .warning, "API severity wins")

print("formatting:")
eq(countdownString(to: now.addingTimeInterval(4 * 3600 + 53 * 60), from: now), "4h 53m", "4h 53m")
eq(countdownString(to: now.addingTimeInterval(23 * 60), from: now), "23m", "23m")
eq(countdownString(to: now.addingTimeInterval(2 * 86400 + 4 * 3600), from: now), "2d 4h", "2d 4h")
eq(countdownString(to: now.addingTimeInterval(-60), from: now), "now", "past -> now")
var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
let next = firstOfNextMonth(after: now, calendar: utc)
eq(utc.dateComponents([.month], from: next).month, 8, "credits reset -> August")
eq(utc.dateComponents([.day], from: next).day, 1, "credits reset -> day 1")

print("credential expiry (drives Keychain re-read so a cached token can't get stuck):")
let realNow = Date()
let expiredCred = ClaudeCredentials(accessToken: "x", refreshToken: nil, expiresAt: realNow.addingTimeInterval(-60), rateLimitTier: nil, subscriptionType: nil)
check(expiredCred.isExpired, "past-expiry token isExpired")
check(expiredCred.expiresSoon(), "past-expiry token expiresSoon")
let soonCred = ClaudeCredentials(accessToken: "x", refreshToken: nil, expiresAt: realNow.addingTimeInterval(30), rateLimitTier: nil, subscriptionType: nil)
check(!soonCred.isExpired, "token 30s out is not yet expired")
check(soonCred.expiresSoon(), "token 30s out expiresSoon -> forces a Keychain re-read")
let freshCred = ClaudeCredentials(accessToken: "x", refreshToken: nil, expiresAt: realNow.addingTimeInterval(3600), rateLimitTier: nil, subscriptionType: nil)
check(!freshCred.isExpired && !freshCred.expiresSoon(), "token with 1h left: neither expired nor expiring")

print("no-data vs placeholder (widget must not show fabricated numbers as real):")
let nd = UsageSnapshot.noData(now: now)
check(nd.stale, "noData is stale")
check(nd.session == nil && nd.weeklyAll == nil && nd.weeklyScoped == nil && nd.credits == nil, "noData has no limits (nothing fabricated)")
check(nd.error != nil, "noData carries a user-facing message")
check(!UsageSnapshot.placeholder(now: now).stale, "placeholder is not stale (preview/gallery only)")

print(String(repeating: "-", count: 40))
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
