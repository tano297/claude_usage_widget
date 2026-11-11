import Foundation
import ClaudeUsageCore
import RosterCore

// Roster sign-in and credits back-off checks. Every response comes from StubURLProtocol: nothing
// here reaches Anthropic, the Keychain, or `/usr/bin/security`. Tokens are fake strings.

/// Answers each request from a queue the check fills, and records what was asked.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var seen: [(url: String, body: String)] = []

    static func reset(_ queue: [Reply]) {
        lock.lock(); replies = queue; seen = []; lock.unlock()
    }

    static var requests: [(url: String, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func count(_ fragment: String) -> Int {
        requests.filter { $0.url.contains(fragment) }.count
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = ""
        if let data = request.httpBody {
            body = String(data: data, encoding: .utf8) ?? ""
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = String(data: data, encoding: .utf8) ?? ""
        }
        Self.lock.lock()
        Self.seen.append((request.url?.absoluteString ?? "", body))
        let reply = Self.replies.isEmpty ? Reply(status: 599, body: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// In-memory token store. `loads` can hand out a different token on a later load, and `saveResults`
/// can refuse saves, like a locked keychain.
final class FakeTokenStore: RosterTokenStore {
    var tokens: [UUID: String] = [:]
    var savedAt: Date?
    var nextLoads: [String] = []
    var saveResults: [Bool] = []
    var saveCalls: [String] = []

    func load(id: UUID) -> RosterTokenLoad {
        if !nextLoads.isEmpty { tokens[id] = nextLoads.removeFirst() }
        guard let token = tokens[id] else { return .missing }
        return .token(token, savedAt: savedAt)
    }

    func save(id: UUID, email: String, refreshToken: String) -> Bool {
        saveCalls.append(refreshToken)
        let ok = saveResults.isEmpty ? true : saveResults.removeFirst()
        if ok { tokens[id] = refreshToken }
        return ok
    }
}

/// A mutable clock for the checks.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class CountingGate: CreditsFetchGate {
    var isEnabled = true
    func disable(reason: CreditsDisableReason) { isEnabled = false }
}

private let usageOK = """
{"five_hour":{"utilization":12,"resets_at":"2026-11-11T20:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-11-14T20:00:00Z"}}
"""

private func tokenOK(access: String, refresh: String) -> StubURLProtocol.Reply {
    .init(status: 200, body: #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":28800}"#)
}

@MainActor
func runRosterChecks() async {
    print("\nroster sign-in")
    let start = parseISODate("2026-11-11T10:00:00Z")!
    let clock = TestClock(start)
    var lines: [String] = []
    func makeSync(_ store: FakeTokenStore) -> RosterSync {
        lines = []
        let api = RosterAPI(session: StubURLProtocol.session(), now: { clock.now })
        return RosterSync(api: api, store: store, now: { clock.now }, log: { lines.append($0) })
    }

    // OAuth error codes: only a short identifier is kept, never free text.
    eq(RosterOAuthErrorCode.parse(Data(#"{"error":"invalid_grant","error_description":"x"}"#.utf8)),
       "invalid_grant", "OAuth error code read")
    eq(RosterOAuthErrorCode.parse(Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"m"}}"#.utf8)),
       "rate_limit_error", "Anthropic error type read")
    check(RosterOAuthErrorCode.parse(Data(#"{"error":"has spaces and a token sk-ant-xyz"}"#.utf8)) == nil,
          "free text is not taken as an error code")

    // 1. invalid_grant: one request, then no more; the row says why; the log line says why.
    do {
        let store = FakeTokenStore()
        let id = UUID()
        store.tokens[id] = "fake-refresh-1"
        store.savedAt = start.addingTimeInterval(-8 * 3600)
        let sync = makeSync(store)
        StubURLProtocol.reset([.init(status: 400, body: #"{"error":"invalid_grant","error_description":"Refresh token not found"}"#)])
        var row = RosterAccount(id: id, email: "a@example.com", fetchedAt: start.addingTimeInterval(-180))
        row = await sync.update(row)
        eq(row.signedOut, true, "invalid_grant marks the account signed out")
        eq(row.error, RosterText.revoked, "invalid_grant shows the newer-sign-in text")
        check(row.error?.contains("Sign in again") == true, "the text keeps 'Sign in again'")
        eq(row.fetchedAt, start.addingTimeInterval(-180), "the last time it worked is kept")
        eq(StubURLProtocol.requests.count, 1, "invalid_grant: one request")
        row = await sync.update(row)
        row = await sync.update(row)
        eq(StubURLProtocol.requests.count, 1, "invalid_grant: no request on later cycles")
        let line = lines.first ?? ""
        check(line.contains("account=\(id.uuidString)") && line.contains("status=400")
              && line.contains("error=invalid_grant") && line.contains("tokenAge=8h0m"),
              "log line has id, status, error code, token age  [\(line)]")
        check(!line.contains("fake-refresh") && !line.contains("@") && !line.contains("not found"),
              "log line has no token, email, or body text")
        // Kept across restarts: the flag is in roster.json.
        let encoded = String(data: try! JSONEncoder().encode(row), encoding: .utf8)!
        check(encoded.contains("\"signedOut\":true"), "signed-out flag is written to roster.json")
        let fresh = try! JSONDecoder().decode(RosterAccount.self, from: Data(#"{"id":"\#(id.uuidString)","email":"a@example.com","stale":false}"#.utf8))
        check(fresh.signedOut == nil, "an older roster.json without the flag still decodes")
    }

    // 1b. The Keychain item changed while the request was out: one more try with the new token.
    do {
        let store = FakeTokenStore()
        let id = UUID()
        store.nextLoads = ["fake-refresh-old", "fake-refresh-new"]
        let sync = makeSync(store)
        StubURLProtocol.reset([
            .init(status: 400, body: #"{"error":"invalid_grant"}"#),
            tokenOK(access: "fake-access-2", refresh: "fake-refresh-3"),
            .init(status: 200, body: usageOK)
        ])
        let row = await sync.update(RosterAccount(id: id, email: "b@example.com"))
        check(row.signedOut == nil && row.error == nil && row.fiveHour?.percent == 12,
              "a token rotated under us is retried once and works")
        eq(StubURLProtocol.count("oauth/token"), 2, "re-read retry: two token requests")
        check(StubURLProtocol.requests[1].body.contains("fake-refresh-new"), "the retry uses the re-read token")
        eq(store.tokens[id], "fake-refresh-3", "the rotated token is saved")
    }

    // 2. 400 without invalid_grant: not a sign-out; tried again next cycle.
    do {
        let store = FakeTokenStore()
        let id = UUID()
        store.tokens[id] = "fake-refresh-1"
        let sync = makeSync(store)
        StubURLProtocol.reset([
            .init(status: 400, body: #"{"error":"invalid_request"}"#),
            tokenOK(access: "fake-access", refresh: "fake-refresh-2"),
            .init(status: 200, body: usageOK)
        ])
        var row = await sync.update(RosterAccount(id: id, email: "c@example.com"))
        check(row.signedOut == nil, "400 invalid_request is not a sign-out")
        eq(row.error, RosterText.unreadable, "400 invalid_request reads as a miss")
        check(lines.first?.contains("error=invalid_request") == true, "the miss is logged with its code")
        row = await sync.update(row)
        eq(row.error, nil, "the next cycle tries again and works")
        eq(StubURLProtocol.count("oauth/token"), 2, "400 invalid_request: retried next cycle")
    }

    // 2b. A 401 on the usage read after a fresh refresh: plain text, not stopped.
    do {
        let store = FakeTokenStore()
        let id = UUID()
        store.tokens[id] = "fake-refresh-1"
        let sync = makeSync(store)
        StubURLProtocol.reset([
            tokenOK(access: "fake-access", refresh: "fake-refresh-2"),
            .init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error"}}"#)
        ])
        let row = await sync.update(RosterAccount(id: id, email: "d@example.com"))
        eq(row.error, RosterText.signIn, "usage 401 keeps plain 'Sign in again.'")
        check(row.signedOut == nil, "usage 401 does not stop refreshing")
    }

    // 3. The Keychain refuses the rotated token: kept in memory, retried, used for the next refresh.
    do {
        let store = FakeTokenStore()
        let id = UUID()
        store.tokens[id] = "fake-refresh-1"
        store.saveResults = [false, false]
        let sync = makeSync(store)
        StubURLProtocol.reset([
            tokenOK(access: "fake-access-1", refresh: "fake-refresh-2"),
            .init(status: 200, body: usageOK),
            .init(status: 200, body: usageOK)
        ])
        var row = await sync.update(RosterAccount(id: id, email: "e@example.com"))
        eq(row.error, RosterText.saveFailed, "a refused save is shown on the row")
        check(row.fiveHour?.percent == 12, "the meters still update")
        check(sync.hasUnsavedRefreshToken(for: id), "the rotated token is kept in memory")
        eq(store.tokens[id], "fake-refresh-1", "the Keychain still has the spent token")
        // Next cycle (access token still good): the save is retried and refused again.
        row = await sync.update(row)
        eq(store.saveCalls.count, 2, "the save is retried on the next cycle")
        // The access token expires; the refresh must use the in-memory token, not the spent one.
        clock.now = start.addingTimeInterval(9 * 3600)
        StubURLProtocol.reset([
            tokenOK(access: "fake-access-2", refresh: "fake-refresh-3"),
            .init(status: 200, body: usageOK)
        ])
        row = await sync.update(row) // this cycle's retried save succeeds (no more refusals queued)
        check(StubURLProtocol.requests.first?.body.contains("fake-refresh-2") == true,
              "the refresh uses the token held in memory")
        eq(store.tokens[id], "fake-refresh-3", "the newest token reaches the Keychain")
        check(!sync.hasUnsavedRefreshToken(for: id) && row.error == nil, "the row clears once saved")
        clock.now = start
    }

    print("\ncredits back-off")
    eq(CreditsBackoff.parseRetryAfter("120", now: start), 120, "Retry-After seconds")
    eq(CreditsBackoff.parseRetryAfter("Wed, 11 Nov 2026 10:05:00 GMT", now: start), 300, "Retry-After date")
    check(CreditsBackoff.parseRetryAfter("soon", now: start) == nil, "unreadable Retry-After is ignored")
    eq(CreditsOutcomeMapper.decision(for: .throttled(retryAfter: 60)), .backOff(retryAfter: 60),
       "429 -> back off, no breaker")

    // 4. 429: no credits request (and no Keychain read) until the back-off ends.
    do {
        let gate = CountingGate()
        let backoff = CreditsBackoff()
        let reads = Counter()
        let previous = CreditsInfo(usedMinor: 500, limitMinor: 10_000, balanceMinor: nil,
                                   currency: "USD", exponent: 2, resetsAt: nil)
        let session = StubURLProtocol.session()
        func fetch() async -> CreditsInfo? {
            await CreditsClient.fetchCredits(gate: gate, backoff: backoff, previous: previous,
                                             now: { clock.now },
                                             readCredential: {
                                                 reads.bump()
                                                 return Data(#"{"claudeAiOauth":{"accessToken":"fake-access"}}"#.utf8)
                                             },
                                             session: session)
        }
        let spend = #"{"spend":{"used":{"amount_minor":700,"currency":"USD","exponent":2},"limit":{"amount_minor":10000},"percent":7,"severity":"normal","enabled":true}}"#
        StubURLProtocol.reset([
            .init(status: 429, body: "{}", headers: ["Retry-After": "600"]),
            .init(status: 429, body: "{}"),
            .init(status: 200, body: spend)
        ])
        clock.now = start
        var got = await fetch()
        eq(got, previous, "429 keeps the last good value")
        eq(StubURLProtocol.requests.count, 1, "429: one request")
        clock.now = start.addingTimeInterval(180)
        got = await fetch()
        clock.now = start.addingTimeInterval(540)
        got = await fetch()
        eq(StubURLProtocol.requests.count, 1, "no credits request during the Retry-After wait")
        eq(reads.value, 1, "no Keychain read during the wait")
        eq(got, previous, "the last good value stays during the wait")
        clock.now = start.addingTimeInterval(601)
        got = await fetch()
        eq(StubURLProtocol.requests.count, 2, "the wait ends: one more request")
        eq(backoff.notBefore, start.addingTimeInterval(601 + 600), "no Retry-After: 2nd strike waits 10 min")
        clock.now = start.addingTimeInterval(601 + 599)
        _ = await fetch()
        eq(StubURLProtocol.requests.count, 2, "still waiting one second before the end")
        clock.now = start.addingTimeInterval(601 + 600)
        got = await fetch()
        eq(got?.usedMinor, 700, "a 200 shows the new value")
        eq(backoff.notBefore, nil, "a 200 clears the back-off")
        let fresh = CreditsBackoff()
        var waits: [TimeInterval] = []
        for _ in 0..<6 { waits.append(fresh.recordThrottle(retryAfter: nil, at: start)) }
        eq(waits, [300, 600, 1200, 2400, 3600, 3600], "doubling from 5 min, capped at 1 hour")
        clock.now = start
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
