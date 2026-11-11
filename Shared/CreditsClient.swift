import Foundation
import os

// MARK: - Narrow endpoint shapes

/// The only values the supplemental endpoint is allowed to contribute. Unknown response keys are
/// unreachable through the private Decodable shapes below and therefore cannot enter a snapshot.
public struct CreditsSpend: Sendable, Equatable {
    public let usedMinor: Int
    public let limitMinor: Int
    public let currency: String
    public let exponent: Int
    public let percent: Double
    public let severity: String
    public let enabled: Bool

    public init(usedMinor: Int,
                limitMinor: Int,
                currency: String,
                exponent: Int,
                percent: Double,
                severity: String,
                enabled: Bool) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.currency = currency
        self.exponent = exponent
        self.percent = percent
        self.severity = severity
        self.enabled = enabled
    }

    fileprivate var creditsInfo: CreditsInfo {
        CreditsInfo(usedMinor: usedMinor,
                    limitMinor: limitMinor,
                    balanceMinor: nil,
                    currency: currency,
                    exponent: exponent,
                    resetsAt: nil)
    }
}

private struct RawCreditsResponse: Decodable {
    let spend: RawSpend
}

private struct RawSpend: Decodable {
    let used: RawUsedAmount
    let limit: RawLimitAmount
    let percent: Double
    let severity: String
    let enabled: Bool
}

private struct RawUsedAmount: Decodable {
    let amountMinor: Int
    let currency: String
    let exponent: Int

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
    }
}

private struct RawLimitAmount: Decodable {
    let amountMinor: Int

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
    }
}

private struct RawClaudeCredentials: Decodable {
    let claudeAiOauth: RawClaudeOAuth
}

private struct RawClaudeOAuth: Decodable {
    let accessToken: String
}

public enum CreditsParser {
    public static func parseSpend(_ data: Data) throws -> CreditsSpend {
        let raw = try JSONDecoder().decode(RawCreditsResponse.self, from: data).spend
        return CreditsSpend(usedMinor: raw.used.amountMinor,
                            limitMinor: raw.limit.amountMinor,
                            currency: raw.used.currency,
                            exponent: raw.used.exponent,
                            percent: raw.percent,
                            severity: raw.severity,
                            enabled: raw.enabled)
    }

    /// Decode exactly the credential field needed for the request. Callers must keep the returned
    /// token local; it must never be logged, persisted, or embedded in an error value.
    public static func parseAccessToken(_ data: Data) throws -> String {
        let token = try JSONDecoder().decode(RawClaudeCredentials.self, from: data)
            .claudeAiOauth.accessToken
        guard !token.isEmpty else { throw CreditsCredentialFailure.malformedOutput }
        return token
    }
}

// MARK: - Breaker decisions

public enum CreditsCredentialFailure: String, Error, Sendable, Equatable, CaseIterable {
    case launchFailed
    case nonzeroExit
    case emptyOutput
    case malformedOutput
    case timedOut
    /// A `security` call that exited 0 only after blocking long enough to imply a Keychain dialog
    /// was shown and answered. The read succeeded, but it was not promptless.
    case promptSuspected
}

/// Persist only these short, fixed reasons. No subprocess or response content is ever copied into
/// breaker state.
public enum CreditsDisableReason: String, Sendable, Equatable {
    case keychainAccess = "Keychain access no longer promptless"
    case forbidden = "Usage credits access was rejected"
}

public enum CreditsFetchEvent: Sendable, Equatable {
    case response(CreditsSpend)
    case httpStatus(Int)
    /// HTTP 429, with the server's Retry-After in seconds when it sent one.
    case throttled(retryAfter: TimeInterval?)
    case credentialFailure(CreditsCredentialFailure)
    case transportFailure
    case malformedResponse
}

public enum CreditsFetchDecision: Sendable, Equatable {
    case show(CreditsInfo)
    case hide
    case disable(CreditsDisableReason)
    /// Keep the last good value and skip the endpoint until the back-off ends.
    case backOff(retryAfter: TimeInterval?)
}

public enum CreditsOutcomeMapper {
    /// Only a Keychain read that is no longer promptless — failed, hung, or slow enough to imply an
    /// answered dialog — or HTTP 403 opens the breaker. Authentication refreshes, throttling,
    /// server failures, transport failures, and malformed endpoint responses are cycle-local misses
    /// so the primary usage pipeline remains unaffected.
    public static func decision(for event: CreditsFetchEvent) -> CreditsFetchDecision {
        switch event {
        case .response(let spend):
            return spend.enabled ? .show(spend.creditsInfo) : .hide
        case .httpStatus(403):
            return .disable(.forbidden)
        case .throttled(let retryAfter):
            return .backOff(retryAfter: retryAfter)
        case .credentialFailure(.promptSuspected):
            // A prompt-tainted success is discarded like a failure: the user already answered one
            // dialog, and the breaker is what stops every future poll from asking again.
            return .disable(.keychainAccess)
        case .credentialFailure:
            return .disable(.keychainAccess)
        case .httpStatus, .transportFailure, .malformedResponse:
            return .hide
        }
    }
}

// MARK: - Rate-limit back-off

/// When the credits endpoint answers 429, no credits request (and no Keychain read) happens until
/// this says so. Retry-After wins when the server sends it (capped at `maxRetryAfter`); otherwise
/// the wait doubles from `initialDelay` up to `maxDelay`. A 200 resets it. In memory only.
public final class CreditsBackoff: @unchecked Sendable {
    public static let initialDelay: TimeInterval = 5 * 60
    public static let maxDelay: TimeInterval = 60 * 60
    public static let maxRetryAfter: TimeInterval = 6 * 60 * 60

    private let lock = NSLock()
    private var strikes = 0
    private var until: Date?

    public init() {}

    /// The time before which no request is made. Nil when requests are allowed.
    public var notBefore: Date? {
        lock.lock(); defer { lock.unlock() }
        return until
    }

    public func allows(at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until else { return true }
        return now >= until
    }

    /// Records one 429 and returns the wait it chose.
    @discardableResult
    public func recordThrottle(retryAfter: TimeInterval?, at now: Date) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        strikes += 1
        let doubling = min(Self.maxDelay, Self.initialDelay * pow(2, Double(min(strikes - 1, 16))))
        let delay = retryAfter.map { min(max($0, 0), Self.maxRetryAfter) } ?? doubling
        until = now.addingTimeInterval(delay)
        return delay
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        strikes = 0
        until = nil
    }

    /// Retry-After as seconds, or as an HTTP date. Nil when absent or unreadable.
    public static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Injected boundary for the persistent auto-disable breaker. The app owns the UserDefaults
/// implementation; the shared client knows only whether it may try and how to disable future tries.
@MainActor
public protocol CreditsFetchGate: AnyObject {
    var isEnabled: Bool { get }
    func disable(reason: CreditsDisableReason)
}

// MARK: - Supplemental fetch

public enum CreditsClient {
    static let credentialTimeout: TimeInterval = 4
    static let requestTimeout: TimeInterval = 15
    /// A genuinely promptless Keychain read returns in about ten milliseconds. Anything slower can
    /// only be a dialog a human sat in front of.
    static let promptlessReadCeiling: TimeInterval = 1
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Classify a `security` call that exited 0 by how long it blocked. Pure so the breaker table
    /// is checkable without spawning a subprocess.
    public static func promptTaint(elapsed: TimeInterval) -> CreditsCredentialFailure? {
        elapsed > promptlessReadCeiling ? .promptSuspected : nil
    }

    /// Best-effort only: every failure returns nil, and only explicit breaker decisions mutate the
    /// injected gate. The primary Claude CLI snapshot is never read or changed here.
    ///
    /// With a `backoff`, an HTTP 429 starts a wait. Until it ends no Keychain read and no request
    /// happen, and `previous` (the last good value) is returned. `readCredential` and `session` are
    /// for checks only; the app leaves them nil.
    public static func fetchCredits(gate: any CreditsFetchGate,
                                    backoff: CreditsBackoff? = nil,
                                    previous: CreditsInfo? = nil,
                                    now: @escaping @Sendable () -> Date = { Date() },
                                    readCredential: (@Sendable () throws -> Data)? = nil,
                                    session: URLSession? = nil) async -> CreditsInfo? {
        guard await gate.isEnabled else { return nil }
        if let backoff, !backoff.allows(at: now()) { return previous }

        let event: CreditsFetchEvent
        do {
            // Security boundary: the token remains a local value for this one request. It is never
            // attached to an error, returned in an outcome, logged, or persisted.
            let credentialData = try (readCredential ?? readCredentialData)()
            let accessToken: String
            do {
                accessToken = try CreditsParser.parseAccessToken(credentialData)
            } catch {
                event = .credentialFailure(.malformedOutput)
                return await apply(CreditsOutcomeMapper.decision(for: event), to: gate,
                                   backoff: backoff, previous: previous, now: now())
            }
            event = await requestSpend(accessToken: accessToken, session: session, now: now())
        } catch let failure as CreditsCredentialFailure {
            event = .credentialFailure(failure)
        } catch {
            event = .credentialFailure(.launchFailed)
        }

        return await apply(CreditsOutcomeMapper.decision(for: event), to: gate,
                           backoff: backoff, previous: previous, now: now())
    }

    private static let logger = Logger(subsystem: "com.claudeusage.app", category: "credits")

    @MainActor
    private static func apply(_ decision: CreditsFetchDecision,
                              to gate: any CreditsFetchGate,
                              backoff: CreditsBackoff?,
                              previous: CreditsInfo?,
                              now: Date) -> CreditsInfo? {
        switch decision {
        case .show(let credits):
            backoff?.reset()
            return gate.isEnabled ? credits : nil
        case .hide:
            return nil
        case .disable(let reason):
            gate.disable(reason: reason)
            return nil
        case .backOff(let retryAfter):
            guard let backoff else { return nil }
            let wait = backoff.recordThrottle(retryAfter: retryAfter, at: now)
            let header = retryAfter.map { String(Int($0)) } ?? "none"
            logger.log("credits status=429 retryAfter=\(header, privacy: .public) wait=\(Int(wait), privacy: .public)s")
            return gate.isEnabled ? previous : nil
        }
    }

    private static func requestSpend(accessToken: String, session injected: URLSession?, now: Date) async -> CreditsFetchEvent {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UsageClient.creditsUserAgent(), forHTTPHeaderField: "User-Agent")

        let session: URLSession
        if let injected {
            session = injected
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            session = URLSession(configuration: configuration,
                                 delegate: NoRedirectSessionDelegate.shared,
                                 delegateQueue: nil)
        }
        defer { if injected == nil { session.invalidateAndCancel() } }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transportFailure }
            if http.statusCode == 429 {
                let header = http.value(forHTTPHeaderField: "Retry-After")
                return .throttled(retryAfter: CreditsBackoff.parseRetryAfter(header, now: now))
            }
            guard http.statusCode == 200 else { return .httpStatus(http.statusCode) }
            guard let spend = try? CreditsParser.parseSpend(data) else { return .malformedResponse }
            return .response(spend)
        } catch {
            return .transportFailure
        }
    }

    /// Spawn exactly /usr/bin/security with closed stdin, discarded stderr, and only HOME/USER.
    /// A four-second timer terminates a read that may be blocked behind a future Keychain dialog,
    /// and a success slower than `promptlessReadCeiling` is discarded as prompt-tainted.
    private static func readCredentialData() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.environment = securityEnvironment()

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let startedAt: Date
        do {
            startedAt = Date()
            try process.run()
        } catch {
            throw CreditsCredentialFailure.launchFailed
        }

        let timeoutState = ProcessTimeoutState()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + credentialTimeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            timeoutState.markTimedOut()
            process.terminate()
            // SIGTERM can be ignored; SIGKILL from the timer fires even while the caller is still
            // blocked reading the pipe, so a wedged child cannot stall the refresh loop.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()

        defer {
            timer.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                // Today's binary exits on SIGTERM; escalate anyway so a child that ignores it can
                // never wedge the caller in `waitUntilExit()`.
                Thread.sleep(forTimeInterval: 1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }

        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.isRunning { process.waitUntilExit() }
        let elapsed = Date().timeIntervalSince(startedAt)

        if timeoutState.didTimeOut { throw CreditsCredentialFailure.timedOut }
        guard process.terminationStatus == 0 else { throw CreditsCredentialFailure.nonzeroExit }
        guard !data.isEmpty else { throw CreditsCredentialFailure.emptyOutput }
        // Security boundary: under a hardened ACL a dialog answered inside the deadline still exits
        // 0. Discard that output rather than let a promptless supplement become a recurring prompt.
        if let taint = promptTaint(elapsed: elapsed) { throw taint }
        return data
    }

    private static func securityEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        if let home = source["HOME"], !home.isEmpty {
            environment["HOME"] = home
        } else if let password = getpwuid(getuid()), let directory = password.pointee.pw_dir {
            environment["HOME"] = String(cString: directory)
        }
        if let user = source["USER"], !user.isEmpty {
            environment["USER"] = user
        } else if let password = getpwuid(getuid()), let name = password.pointee.pw_name {
            environment["USER"] = String(cString: name)
        }
        return environment
    }
}

/// Keep the bearer request pinned to the one documented-in-code host/path. Redirects are surfaced
/// as ordinary non-200 responses instead of forwarding the credential to another URL. The roster
/// requests use it too.
public final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = NoRedirectSessionDelegate()

    public func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class ProcessTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}
