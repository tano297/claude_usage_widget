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

@MainActor
final class EphemeralCreditsGate: CreditsFetchGate {
    var isEnabled = true
    private(set) var disableReason: CreditsDisableReason?

    func disable(reason: CreditsDisableReason) {
        isEnabled = false
        disableReason = reason
    }
}

// Live mode exercises the CLI pipeline plus the isolated best-effort credits supplement.
if CommandLine.arguments.contains("--live") {
    Task { @MainActor in
        var snapshot = await UsageClient.fetchSnapshot()
        let creditsGate = EphemeralCreditsGate()
        // Exercise the supplement independently for diagnostics even when this shell cannot access
        // Claude's primary login. Production still merges credits only after a fresh CLI fetch.
        let liveCredits = await CreditsClient.fetchCredits(gate: creditsGate)
        if !snapshot.stale {
            snapshot.credits = liveCredits
        }
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
        if let credits = liveCredits {
            let used = moneyString(minor: credits.usedMinor,
                                   exponent: credits.exponent,
                                   currency: credits.currency)
            let limit = moneyString(minor: credits.limitMinor,
                                    exponent: credits.exponent,
                                    currency: credits.currency)
            print("  Credits    \(used) / \(limit)")
        } else if let reason = creditsGate.disableReason {
            print("  Credits    disabled — \(reason.rawValue)")
        } else if !snapshot.stale {
            print("  Credits    unavailable this cycle (breaker remains enabled)")
        }
        exit(0)
    }
    RunLoop.main.run()
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

print("supplemental credits spend allowlist:")
let enabledSpend = try! CreditsParser.parseSpend(fixture("credits_enabled"))
eq(enabledSpend.usedMinor, 1234, "enabled used amount")
eq(enabledSpend.limitMinor, 9876, "enabled limit amount")
eq(enabledSpend.currency, "USD", "enabled currency")
eq(enabledSpend.exponent, 2, "enabled exponent")
eq(enabledSpend.percent, 12.5, "enabled percent")
eq(enabledSpend.severity, "warning", "enabled severity")
check(enabledSpend.enabled, "enabled flag")

let disabledSpend = try! CreditsParser.parseSpend(fixture("credits_disabled"))
check(!disabledSpend.enabled, "disabled flag")
let nonUSDSpend = try! CreditsParser.parseSpend(fixture("credits_non_usd"))
eq(nonUSDSpend.currency, "KWD", "non-USD currency")
eq(nonUSDSpend.exponent, 3, "non-USD exponent 3")

let showDecision = CreditsOutcomeMapper.decision(for: .response(enabledSpend))
guard case .show(let decodedCredits) = showDecision else {
    check(false, "enabled spend maps to visible credits")
    fatalError("fixture decision should show credits")
}
eq(decodedCredits.usedMinor, 1234, "enabled spend maps used amount")
eq(decodedCredits.limitMinor, 9876, "enabled spend maps limit amount")

// Drive the real credential parser with a fixture blob, then build the snapshot the production way,
// so the containment assertion below is about a token that actually travelled the pipeline.
let credentialBlob = Data(#"{"claudeAiOauth":{"accessToken":"fixture_access_token_never_persist","refreshToken":"fixture_refresh_token_never_persist","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}}"#.utf8)
let parsedToken = try! CreditsParser.parseAccessToken(credentialBlob)
eq(parsedToken, "fixture_access_token_never_persist", "credential blob yields only the access token")
var creditsSnapshot = normal
creditsSnapshot.credits = decodedCredits
let creditsJSON = String(data: try! encoder.encode(creditsSnapshot), encoding: .utf8)!
for forbidden in ["fixture_junk_key", "amber_ladder", "display_hint",
                  parsedToken, "fixture_refresh_token_never_persist"] {
    check(!creditsJSON.contains(forbidden), "credits input discarded from snapshot: \(forbidden)")
}

print("credits outcome mapping + breaker table:")
let outcomeCases: [(CreditsFetchEvent, CreditsFetchDecision, String)] = [
    (.response(enabledSpend), .show(decodedCredits), "enabled success -> show / no breaker"),
    (.response(disabledSpend), .hide, "disabled success -> hide / no breaker"),
    (.httpStatus(401), .hide, "HTTP 401 -> hide / no breaker"),
    (.httpStatus(429), .hide, "HTTP 429 -> hide / no breaker"),
    (.httpStatus(500), .hide, "HTTP 500 -> hide / no breaker"),
    (.httpStatus(503), .hide, "HTTP 503 -> hide / no breaker"),
    (.httpStatus(403), .disable(.forbidden), "HTTP 403 -> breaker"),
    (.credentialFailure(.launchFailed), .disable(.keychainAccess), "security launch failure -> breaker"),
    (.credentialFailure(.nonzeroExit), .disable(.keychainAccess), "security nonzero -> breaker"),
    (.credentialFailure(.emptyOutput), .disable(.keychainAccess), "security empty -> breaker"),
    (.credentialFailure(.malformedOutput), .disable(.keychainAccess), "security malformed -> breaker"),
    (.credentialFailure(.timedOut), .disable(.keychainAccess), "security timeout -> breaker"),
    (.credentialFailure(.promptSuspected), .disable(.keychainAccess),
     "prompt-tainted security success -> hide + breaker"),
    (.transportFailure, .hide, "network failure -> hide / no breaker"),
    (.malformedResponse, .hide, "malformed endpoint response -> hide / no breaker"),
    (.httpStatus(400), .hide, "other HTTP status -> hide / no breaker"),
]
for (event, expected, message) in outcomeCases {
    eq(CreditsOutcomeMapper.decision(for: event), expected, message)
}

print("prompt-tainted credential read (hardened Keychain ACL):")
check(CreditsClient.promptTaint(elapsed: 0.01) == nil, "a promptless ~10ms read stays trusted")
eq(CreditsClient.promptTaint(elapsed: 2.5), .promptSuspected,
   "a success slower than a second means a dialog was answered")
eq(CreditsOutcomeMapper.decision(for: .credentialFailure(.promptSuspected)),
   .disable(.keychainAccess), "slow success -> hide + breaker trip")
eq(CreditsOutcomeMapper.decision(for: .response(enabledSpend)),
   .show(decodedCredits), "fast success -> show + no breaker trip")

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
let withoutCreditsJSON = Data(#"{"fetchedAt":"2026-08-07T18:00:00Z","planLabel":"Pro","session":null,"weeklyAll":null,"weeklyScoped":null,"stale":false,"error":null}"#.utf8)
let withoutCredits = try! decoder.decode(UsageSnapshot.self, from: withoutCreditsJSON)
check(withoutCredits.credits == nil, "snapshot without credits key decodes with nil")
let historicalCreditsJSON = Data(#"{"fetchedAt":"2026-08-07T18:00:00Z","planLabel":"Pro","session":null,"weeklyAll":null,"weeklyScoped":null,"credits":{"usedMinor":321,"limitMinor":6543,"balanceMinor":111,"currency":"USD","exponent":2,"resetsAt":"2026-09-01T00:00:00Z"},"stale":false,"error":null}"#.utf8)
let historicalCredits = try! decoder.decode(UsageSnapshot.self, from: historicalCreditsJSON)
eq(historicalCredits.credits?.usedMinor, 321, "historical credits snapshot still decodes")
let creditsRoundTrip = try! decoder.decode(UsageSnapshot.self, from: encoder.encode(creditsSnapshot))
eq(creditsRoundTrip.credits, decodedCredits, "credits snapshot round trip")

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
// Money formatting follows the user's locale, so these assertions pin one explicitly.
let enUS = Locale(identifier: "en_US")
eq(moneyString(minor: 1234, exponent: 2, currency: "USD", locale: enUS), "$12.34", "USD minor units")
check(moneyString(minor: nonUSDSpend.usedMinor,
                  exponent: nonUSDSpend.exponent,
                  currency: nonUSDSpend.currency,
                  locale: enUS).contains("1.250"),
      "exponent-3 money keeps three fractional digits")

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

print("roster usage:")
let rosterNow = parseISODate("2026-10-13T18:00:00Z")!
let rosterParsed = try! RosterUsageParser.parse(fixture("roster_usage"))
eq(rosterParsed.fiveHour?.percent, 12, "limits session wins over five_hour")
eq(rosterParsed.week?.percent, 40, "limits weekly_all wins over seven_day")
eq(rosterParsed.fiveHour?.severity, .normal, "session severity from the payload")
eq(rosterParsed.week?.resetsAt, parseISODate("2026-10-16T03:00:00Z"), "weekly reset instant")
let legacy = try! RosterUsageParser.parse(fixture("roster_usage_legacy"))
eq(legacy.fiveHour?.percent, 15, "legacy five_hour utilization")
eq(legacy.week?.percent, 60.4, "legacy seven_day utilization")
check((try? RosterUsageParser.parse(fixture("roster_usage_empty"))) == nil, "empty payload is not a fake zero")
check((try? RosterUsageParser.parse(Data("not json".utf8))) == nil, "non-json usage is unreadable")

let clockZone = TimeZone(secondsFromGMT: 0)!
let clockLocale = Locale(identifier: "en_US")
eq(resetClockString(parseISODate("2026-10-16T03:00:00Z")!, locale: clockLocale, timeZone: clockZone),
   "Fri 3:00 AM",
   "reset clock is weekday and time")
eq(rosterShortName("longlocalpart@example.com"), "longlocalpar", "short name is the local part, capped")
eq(rosterShortName("ada.297@example.com"), "ada.297", "short local part stays whole")
eq(rosterMeter(nil, now: rosterNow), "—", "missing window is an em dash")
eq(rosterMeter(LimitBar(percent: 4.2, resetsAt: parseISODate("2026-10-13T22:00:00Z"), severity: .normal),
               now: rosterNow),
   "4% 4h 0m",
   "meter is rounded percent and countdown")

let sampleAccounts = [
    RosterAccount(email: "ada.297@example.com",
                  fiveHour: LimitBar(percent: 4, resetsAt: rosterNow.addingTimeInterval(4 * 3600), severity: .normal),
                  week: LimitBar(percent: 89, resetsAt: rosterNow.addingTimeInterval(3 * 86_400 + 4 * 3600), severity: .warning)),
    RosterAccount(email: "other@example.com",
                  fiveHour: nil,
                  week: LimitBar(percent: 10, resetsAt: nil, severity: .normal))
]
eq(rosterStatusText(sampleAccounts, now: rosterNow),
   "ada.297 4% 4h 0m · 89% 3d 4h  other — · 10% —",
   "menu bar chip per account")
eq(rosterStatusText([], now: rosterNow), "", "empty roster has no menu bar text")
eq(hourMinuteString(to: rosterNow.addingTimeInterval(4 * 3600 + 60), from: rosterNow),
   "4h 1m",
   "5-hour reset is hours and minutes")
eq(hourMinuteString(to: rosterNow.addingTimeInterval(27 * 3600 + 5 * 60), from: rosterNow),
   "27h 5m",
   "5-hour reset does not roll into days")
eq(hourMinuteString(to: rosterNow.addingTimeInterval(45 * 60), from: rosterNow),
   "45m",
   "5-hour reset under an hour is minutes")
eq(readingAgeString(from: rosterNow.addingTimeInterval(-12), to: rosterNow),
   "12 sec ago",
   "a fresh reading is seconds")
eq(readingAgeString(from: rosterNow.addingTimeInterval(-3 * 60), to: rosterNow),
   "3 min ago",
   "an older reading is minutes")
eq(readingAgeString(from: rosterNow.addingTimeInterval(-(60 * 60 + 5 * 60)), to: rosterNow),
   "1 hr 5 min ago",
   "a reading past an hour keeps the minutes")
let soon = RosterAccount(email: "soon@example.com",
                         week: LimitBar(percent: 10, resetsAt: rosterNow.addingTimeInterval(2 * 3600), severity: .normal))
let later = RosterAccount(email: "later@example.com",
                          week: LimitBar(percent: 20, resetsAt: rosterNow.addingTimeInterval(2 * 86_400), severity: .normal))
let unknown = RosterAccount(email: "unknown@example.com",
                            week: LimitBar(percent: 30, resetsAt: nil, severity: .normal))
eq(rosterByWeeklyReset([later, unknown, soon]).map(\.email),
   ["soon@example.com", "later@example.com", "unknown@example.com"],
   "weekly reset soonest first, missing reset last")

let rosterDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("claude-usage-roster-\(UUID().uuidString)", isDirectory: true)
RosterStore.directoryOverride = rosterDir
defer { RosterStore.directoryOverride = nil }
let stored = RosterSnapshot(accounts: sampleAccounts)
try! RosterStore.save(stored)
let loaded = RosterStore.load()
eq(loaded, stored, "roster round trip")
let rawRoster = String(data: try! Data(contentsOf: RosterStore.fileURL()), encoding: .utf8)!
check(!rawRoster.contains("sk-ant"), "roster file has no session material")
check(rawRoster.contains("ada.297@example.com"), "roster file keeps the email")
try? FileManager.default.removeItem(at: rosterDir)

print(String(repeating: "-", count: 40))
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
