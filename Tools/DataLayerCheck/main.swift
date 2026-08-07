import Foundation
import ClaudeUsageCore

// Lightweight assertion harness — no XCTest, so it runs with Command Line Tools alone.
var failures = 0
func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)  (line \(line))")
    }
}
func eq<T: Equatable>(_ actual: T?, _ expected: T, _ message: String, line: UInt = #line) {
    check(actual == expected,
          "\(message)  [\(String(describing: actual)) == \(expected)]",
          line: line)
}

// Live mode exercises the same two-subprocess pipeline as the menu-bar agent.
if CommandLine.arguments.contains("--live") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let snapshot = await UsageClient.fetchSnapshot()
        print("LIVE snapshot — plan: \(snapshot.planLabel)\(snapshot.stale ? "  [STALE]" : "")")
        if let email = snapshot.email { print("  account: \(email)") }
        if let error = snapshot.error { print("  error: \(error)") }
        func line(_ name: String, _ bar: LimitBar?) {
            guard let bar else { return }
            let reset = bar.resetsAt.map { "resets in " + countdownString(to: $0, from: Date()) } ?? "—"
            print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(percentString(bar.percent))  · \(reset)  [\(bar.severity)]")
        }
        line("Session", snapshot.session)
        line("Weekly", snapshot.weeklyAll)
        for scoped in snapshot.weeklyScoped ?? [] { line("Weekly·\(scoped.name)", scoped.bar) }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // DataLayerCheck
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // repo root
func fixture(_ name: String) -> Data {
    try! Data(contentsOf: repoRoot.appendingPathComponent("fixtures/\(name).json"))
}

let now = parseISODate("2026-08-07T18:00:00Z")!
func parse(_ name: String,
           label: String = "Max",
           email: String? = nil,
           at date: Date = now) throws -> UsageSnapshot {
    try UsageParser.parse(fixture(name), planLabel: label, email: email, now: date, fetchedAt: date)
}
func expectParseFailure(_ name: String,
                        expected: UsageParseError? = nil,
                        line: UInt = #line) {
    do {
        _ = try parse(name)
        check(false, "\(name) is rejected", line: line)
    } catch {
        if let expected {
            eq(error as? UsageParseError, expected, "\(name) failure kind", line: line)
        } else {
            check(true, "\(name) is rejected", line: line)
        }
    }
}

print("normal envelope (three whitelisted bars):")
let normal = try! parse("normal")
eq(normal.session?.percent, 15, "session 15%")
eq(normal.session?.severity, .normal, "session severity derived")
eq(normal.weeklyAll?.percent, 3, "weekly 3%")
eq(normal.weeklyScoped?.count, 1, "one scoped weekly bar")
eq(normal.weeklyScoped?.first?.name, "Fable", "scoped name captured")
eq(normal.weeklyScoped?.first?.bar.percent, 5, "Fable 5%")
check(normal.credits == nil, "CLI prose never fabricates credits")

var denver = Calendar(identifier: .gregorian)
denver.timeZone = TimeZone(identifier: "America/Denver")!
eq(normal.session?.resetsAt.map { denver.component(.hour, from: $0) }, 19, "12-hour reset hour parsed")
eq(normal.session?.resetsAt.map { denver.component(.minute, from: $0) }, 29, "reset minutes parsed")

print("multiple model scopes + ASCII separator fallback:")
let multiple = try! parse("multiple_scoped")
eq(multiple.session?.percent, 49, "ASCII separator session parsed")
eq(multiple.weeklyAll?.percent, 89, "weekly all parsed")
eq(multiple.weeklyScoped?.count, 2, "several scoped lines retained")
eq(multiple.weeklyScoped?.first { $0.name == "Fable" }?.bar.severity, .critical, "90% is critical")
eq(multiple.weeklyScoped?.first { $0.name == "Opus" }?.bar.percent, 100, "Opus 100%")

print("optional/malformed reset handling:")
let missing = try! parse("missing_resets")
check(missing.session?.resetsAt == nil && missing.weeklyAll?.resetsAt == nil,
      "missing reset suffix keeps bars with nil dates")
check(missing.weeklyScoped?.first?.bar.resetsAt == nil, "scoped reset suffix is optional")
let noMinutes = try! parse("no_minutes")
eq(noMinutes.session?.resetsAt.map { denver.component(.hour, from: $0) }, 17, "5pm parses without minutes")
eq(noMinutes.session?.resetsAt.map { denver.component(.minute, from: $0) }, 0, "no-minutes reset uses :00")

let malformedResetData = Data(#"[{"type":"result","subtype":"success","is_error":false,"result":"Current session: 44% used · resets sometime later"}]"#.utf8)
let malformedReset = try! UsageParser.parse(malformedResetData,
                                            planLabel: "Pro",
                                            now: now,
                                            fetchedAt: now)
eq(malformedReset.session?.percent, 44, "malformed reset keeps percent")
check(malformedReset.session?.resetsAt == nil, "malformed reset becomes nil")

print("year-boundary reset handling:")
let decemberNow = parseISODate("2026-12-31T18:00:00Z")!
let boundary = try! parse("year_boundary", at: decemberNow)
eq(boundary.session?.resetsAt.map { denver.component(.year, from: $0) }, 2027,
   "January reset rolls into next year")

print("malformed envelopes and zero-bar result:")
expectParseFailure("not_json")
expectParseFailure("no_result", expected: .missingResult)
expectParseFailure("error_result", expected: .resultError)
expectParseFailure("zero_bars", expected: .noUsageBars)

print("analytics output boundary:")
let analytics = try! parse("analytics_output")
eq(analytics.session?.percent, 16, "full output still yields session")
eq(analytics.weeklyAll?.percent, 4, "full output still yields weekly")
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
let analyticsJSON = String(data: try! encoder.encode(analytics), encoding: .utf8)!
for forbidden in ["FixtureSkillAlpha", "FixtureSubagentBeta", "FixturePluginGamma",
                  "fixture-mcp-server", "Fixture-only assistant content", "Recent activity"] {
    check(!analyticsJSON.contains(forbidden), "analytics string discarded: \(forbidden)")
}

print("auth status allowlist + email propagation:")
let auth = try! UsageParser.parseAuthStatus(fixture("auth_status"))
check(auth.loggedIn, "loggedIn decoded")
eq(auth.email, "user@example.com", "invented fixture email decoded")
eq(auth.subscriptionType, "max", "subscription type decoded")
let signedOutAuth = try! UsageParser.parseAuthStatus(
    Data(#"{"loggedIn":false,"email":null,"subscriptionType":null}"#.utf8))
check(!signedOutAuth.loggedIn, "explicit signed-out auth status decoded")
let accountSnapshot = try! parse("analytics_output",
                                 label: planLabel(subscriptionType: auth.subscriptionType),
                                 email: auth.email)
eq(accountSnapshot.email, "user@example.com", "email lands in snapshot")
let accountJSON = String(data: try! encoder.encode(accountSnapshot), encoding: .utf8)!
check(accountJSON.contains("user@example.com"), "encoded snapshot contains account email")
for forbidden in ["orgId", "orgName", "org_fixture_123", "Example Fixture Org", "authMethod"] {
    check(!accountJSON.contains(forbidden), "auth field never reaches snapshot: \(forbidden)")
}

print("plan labels:")
eq(planLabel(subscriptionType: "max"), "Max", "max")
eq(planLabel(subscriptionType: "PRO"), "Pro", "pro case-insensitive")
eq(planLabel(subscriptionType: "team"), "Team", "team")
eq(planLabel(subscriptionType: "free"), "Free", "free")
eq(planLabel(subscriptionType: "enterprise"), "Enterprise", "enterprise")
eq(planLabel(subscriptionType: "research preview"), "Research Preview", "other values capitalized")
eq(planLabel(subscriptionType: nil), "Claude", "absent fallback")
eq(planLabel(subscriptionType: "  "), "Claude", "empty fallback")

print("menu bar summary (all windows, labeled):")
eq(menuBarSummary(normal), "S15 W3 F5", "normal fixture summary")
eq(menuBarSummary(multiple), "S49 W89 F90 O100", "multiple scopes summary")
eq(menuBarSummary(nil), "—", "nil snapshot -> em dash")
eq(menuBarSummary(UsageSnapshot.noData(now: now)), "—", "noData -> em dash")
var collision = normal
collision.weeklyScoped = [ScopedLimit(name: "Sonnet",
                                      bar: LimitBar(percent: 45.6, resetsAt: nil, severity: .normal))]
eq(menuBarSummary(collision), "S15 W3 So46", "label collision uses two letters")

print("severity derivation:")
eq(Severity.from(percent: 10, apiValue: nil), .normal, "10% normal")
eq(Severity.from(percent: 75, apiValue: nil), .warning, "75% warning")
eq(Severity.from(percent: 96, apiValue: nil), .critical, "96% critical")
eq(Severity.from(percent: 5, apiValue: "warning"), .warning, "explicit severity still supported")

print("snapshot Codable compatibility:")
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let roundTrip = try! decoder.decode(UsageSnapshot.self, from: encoder.encode(accountSnapshot))
eq(roundTrip, accountSnapshot, "current snapshot round trip")
let preEmailJSON = Data(#"{"fetchedAt":"2026-08-07T18:00:00Z","planLabel":"Pro","session":null,"weeklyAll":null,"credits":null,"stale":false,"error":null}"#.utf8)
let preEmail = try! decoder.decode(UsageSnapshot.self, from: preEmailJSON)
check(preEmail.email == nil, "snapshot without email decodes with nil")
check(preEmail.weeklyScoped == nil, "older snapshot without weeklyScoped still decodes")

print("formatting:")
eq(countdownString(to: now.addingTimeInterval(4 * 3600 + 53 * 60), from: now), "4h 53m", "4h 53m")
eq(countdownString(to: now.addingTimeInterval(23 * 60), from: now), "23m", "23m")
eq(countdownString(to: now.addingTimeInterval(2 * 86400 + 4 * 3600), from: now), "2d 4h", "2d 4h")
eq(countdownString(to: now.addingTimeInterval(-60), from: now), "now", "past -> now")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let next = firstOfNextMonth(after: now, calendar: utc)
eq(utc.dateComponents([.month], from: next).month, 9, "credits reset -> September")
eq(utc.dateComponents([.day], from: next).day, 1, "credits reset -> day 1")

print("threshold planner (notify every 10% per window, every $10 of credits):")
func snap(session: LimitBar? = nil,
          weekly: LimitBar? = nil,
          scoped: [ScopedLimit]? = nil,
          credits: CreditsInfo? = nil,
          stale: Bool = false) -> UsageSnapshot {
    UsageSnapshot(fetchedAt: now, planLabel: "Max", session: session, weeklyAll: weekly,
                  weeklyScoped: scoped, credits: credits, stale: stale, error: nil)
}
func bar(_ percent: Double, resetsIn: TimeInterval = 3600) -> LimitBar {
    LimitBar(percent: percent, resetsAt: now.addingTimeInterval(resetsIn), severity: .normal)
}
let inAnHour = now.addingTimeInterval(3600)

let seeded = ThresholdPlanner.plan(snapshot: snap(session: bar(45), weekly: bar(23)),
                                   state: [:], now: now)
check(seeded.alerts.isEmpty, "first sighting seeds silently")
eq(seeded.state["session"]?.bucket, 4, "session seeded at bucket 4")
eq(seeded.state["weekly"]?.bucket, 2, "weekly seeded at bucket 2")

let crossed = ThresholdPlanner.plan(snapshot: snap(weekly: bar(34)),
                                    state: ["weekly": ThresholdKeyState(bucket: 2, resetsAt: inAnHour)],
                                    now: now)
eq(crossed.alerts.count, 1, "one crossing -> one alert")
eq(crossed.alerts.first?.title, "Claude · Weekly at 30%", "crossing title")
eq(crossed.alerts.first?.body, "resets in 1h 0m", "crossing countdown")
eq(crossed.state["weekly"]?.bucket, 3, "state advances")

let jumped = ThresholdPlanner.plan(snapshot: snap(session: bar(47)),
                                   state: ["session": ThresholdKeyState(bucket: 0, resetsAt: inAnHour)],
                                   now: now)
eq(jumped.alerts.count, 1, "multi-bucket jump -> single alert")
eq(jumped.alerts.first?.title, "Claude · Session at 40%", "jump announces highest threshold")

let fableUp = ThresholdPlanner.plan(
    snapshot: snap(scoped: [ScopedLimit(name: "Fable", bar: bar(82))]),
    state: ["scoped:Fable": ThresholdKeyState(bucket: 7, resetsAt: inAnHour)],
    now: now)
eq(fableUp.alerts.first?.title, "Claude · Weekly · Fable at 80%", "scoped window title")

let maxed = ThresholdPlanner.plan(snapshot: snap(session: bar(100)),
                                  state: ["session": ThresholdKeyState(bucket: 9, resetsAt: inAnHour)],
                                  now: now)
eq(maxed.alerts.first?.title, "Claude · Session limit reached", "bucket 10 -> reached")

let cycled = ThresholdPlanner.plan(
    snapshot: snap(session: bar(12, resetsIn: 7 * 86_400)),
    state: ["session": ThresholdKeyState(bucket: 9, resetsAt: inAnHour)],
    now: now)
check(cycled.alerts.isEmpty, "new cycle reseeds silently")
eq(cycled.state["session"]?.bucket, 1, "new cycle stores fresh bucket")

let dropped = ThresholdPlanner.plan(snapshot: snap(weekly: bar(12)),
                                    state: ["weekly": ThresholdKeyState(bucket: 9, resetsAt: inAnHour)],
                                    now: now)
check(dropped.alerts.isEmpty, "bucket drop reseeds silently")
eq(dropped.state["weekly"]?.bucket, 1, "dropped state reseeded")

let fractionalReset = parseISODate("2026-08-07T20:30:00.577840+00:00")!
let stateRoundTrip = ThresholdPlanner.decodeState(
    ThresholdPlanner.encodeState(["weekly": ThresholdKeyState(bucket: 2, resetsAt: fractionalReset)]))
let afterStateRoundTrip = ThresholdPlanner.plan(
    snapshot: snap(weekly: LimitBar(percent: 34, resetsAt: fractionalReset, severity: .normal)),
    state: stateRoundTrip,
    now: now)
eq(afterStateRoundTrip.alerts.count, 1, "date precision loss does not fake a new cycle")
check(ThresholdPlanner.decodeState(nil).isEmpty && ThresholdPlanner.decodeState("garbage").isEmpty,
      "missing/corrupt threshold state decodes empty")

let credits = CreditsInfo(usedMinor: 6100,
                          limitMinor: 30000,
                          balanceMinor: nil,
                          currency: "USD",
                          exponent: 2,
                          resetsAt: now.addingTimeInterval(30 * 86_400))
let creditsUp = ThresholdPlanner.plan(snapshot: snap(credits: credits),
                                      state: ["credits": ThresholdKeyState(bucket: 4,
                                                                           resetsAt: credits.resetsAt)],
                                      now: now)
eq(creditsUp.alerts.first?.title, "Claude · Credits: $60.00 spent", "credit threshold title")
eq(creditsUp.alerts.first?.body,
   "$300.00 limit · resets \(shortDateString(credits.resetsAt!))",
   "credit threshold body")
eq(creditsUp.state["credits"]?.bucket, 6, "credit state advances")

let staleState = ["session": ThresholdKeyState(bucket: 1, resetsAt: inAnHour)]
let staleRun = ThresholdPlanner.plan(snapshot: snap(session: bar(99), stale: true),
                                     state: staleState,
                                     now: now)
check(staleRun.alerts.isEmpty, "stale snapshot never alerts")
eq(staleRun.state, staleState, "stale snapshot leaves state untouched")

let pruned = ThresholdPlanner.plan(snapshot: snap(session: bar(10)),
                                   state: ["scoped:Opus": ThresholdKeyState(bucket: 5,
                                                                            resetsAt: inAnHour)],
                                   now: now)
check(pruned.state["scoped:Opus"] == nil, "departed windows pruned")

print("no-data vs placeholder:")
let noData = UsageSnapshot.noData(now: now)
check(noData.stale, "noData is stale")
check(noData.email == nil, "noData has no email")
check(noData.session == nil && noData.weeklyAll == nil && noData.weeklyScoped == nil && noData.credits == nil,
      "noData has no fabricated limits")
check(noData.error != nil, "noData carries a user-facing message")
let customNoData = UsageSnapshot.noData(now: now, error: "Fixture-safe error")
eq(customNoData.error, "Fixture-safe error", "noData accepts fixed client error")
check(!UsageSnapshot.placeholder(now: now).stale, "placeholder is preview-only fresh data")
eq(UsageSnapshot.placeholder(now: now).email, "user@example.com", "preview email is invented")

print(String(repeating: "-", count: 40))
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
