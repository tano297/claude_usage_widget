import Foundation

// MARK: - Claude CLI response shapes

public struct ClaudeAuthStatus: Sendable, Equatable {
    public let loggedIn: Bool
    public let email: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, email: String?, subscriptionType: String?) {
        self.loggedIn = loggedIn
        self.email = email
        self.subscriptionType = subscriptionType
    }
}

private struct RawAuthStatus: Decodable {
    let loggedIn: Bool
    let email: String?
    let subscriptionType: String?
}

private struct RawUsageMessage: Decodable {
    let type: String?
    let subtype: String?
    let isError: Bool?
    let result: String?

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case isError = "is_error"
        case result
    }
}

public enum UsageParseError: Error, Equatable {
    case missingResult
    case resultError
    case noUsageBars
}

// MARK: - Parser (pure; checked against fixtures)

public enum UsageParser {
    /// Decode only the three auth fields the snapshot pipeline is allowed to consume. Unknown
    /// fields such as organization identifiers are ignored by `Decodable` and never propagated.
    public static func parseAuthStatus(_ data: Data) throws -> ClaudeAuthStatus {
        let raw = try JSONDecoder().decode(RawAuthStatus.self, from: data)
        return ClaudeAuthStatus(loggedIn: raw.loggedIn,
                                email: raw.email,
                                subscriptionType: raw.subscriptionType)
    }

    /// Find Claude's successful result envelope, then whitelist only the recognized usage-bar
    /// lines. The rest of `/usage` may contain account analytics and extension names; none of that
    /// text is copied into the returned snapshot.
    public static func parse(_ data: Data,
                             planLabel: String,
                             email: String? = nil,
                             now: Date,
                             fetchedAt: Date) throws -> UsageSnapshot {
        let messages = try JSONDecoder().decode([RawUsageMessage].self, from: data)
        guard let message = messages.first(where: { $0.type == "result" }) else {
            throw UsageParseError.missingResult
        }
        guard message.isError == false, message.subtype == "success", let prose = message.result else {
            throw UsageParseError.resultError
        }

        var session: LimitBar?
        var weeklyAll: LimitBar?
        var weeklyScoped: [ScopedLimit] = []

        for rawLine in prose.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            if let match = captures(in: line,
                                    pattern: #"^Current session: ([0-9]+)% used(?: (?:·|-) resets (.+))?$"#),
               let percent = Double(match[0]) {
                session = makeBar(percent: percent, resetText: match[1], now: now)
                continue
            }
            if let match = captures(in: line,
                                    pattern: #"^Current week \(all models\): ([0-9]+)% used(?: (?:·|-) resets (.+))?$"#),
               let percent = Double(match[0]) {
                weeklyAll = makeBar(percent: percent, resetText: match[1], now: now)
                continue
            }
            if let match = captures(in: line,
                                    pattern: #"^Current week \((.+)\): ([0-9]+)% used(?: (?:·|-) resets (.+))?$"#),
               !match[0].isEmpty,
               let percent = Double(match[1]) {
                weeklyScoped.append(ScopedLimit(
                    name: match[0],
                    bar: makeBar(percent: percent, resetText: match[2], now: now)
                ))
            }
        }

        guard session != nil || weeklyAll != nil || !weeklyScoped.isEmpty else {
            throw UsageParseError.noUsageBars
        }

        return UsageSnapshot(fetchedAt: fetchedAt,
                             planLabel: planLabel,
                             email: email,
                             session: session,
                             weeklyAll: weeklyAll,
                             weeklyScoped: weeklyScoped.isEmpty ? nil : weeklyScoped,
                             credits: nil,
                             stale: false,
                             error: nil)
    }

    /// Returns every capture group, using an empty string for an unmatched optional group.
    private static func captures(in value: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value,
                                                range: NSRange(value.startIndex..., in: value)),
              match.range == NSRange(value.startIndex..., in: value) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
            return String(value[swiftRange])
        }
    }

    private static func makeBar(percent: Double, resetText: String, now: Date) -> LimitBar {
        LimitBar(percent: percent,
                 resetsAt: parseResetDate(resetText, now: now),
                 severity: .from(percent: percent, apiValue: nil))
    }

    /// Claude omits the year from reset labels. Interpret the label in its named IANA timezone,
    /// then roll it forward one year when the current-year date is clearly across a year boundary.
    static func parseResetDate(_ value: String, now: Date) -> Date? {
        guard let match = captures(in: value,
                                   pattern: #"^([A-Za-z]{3} [0-9]{1,2} at [0-9]{1,2}(?::[0-9]{2})?[aApP][mM]) \(([^()]+)\)$"#),
              let timeZone = TimeZone(identifier: match[1]) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: now)
        let input = "\(match[0]) \(year)"
        let formats = ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            guard var result = formatter.date(from: input) else { continue }

            if let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now),
               result < sixMonthsAgo,
               let nextYear = calendar.date(byAdding: .year, value: 1, to: result) {
                result = nextYear
            }
            return result
        }
        return nil
    }
}

// MARK: - Process client

private enum UsageClientError: Error {
    case claudeNotFound
    case timedOut
    case signedOut
    case unusableOutput
}

public enum UsageClient {
    static let authTimeout: TimeInterval = 10
    static let usageTimeout: TimeInterval = 30

    /// The supplemental credits request uses the same Claude binary discovery and minimal child
    /// environment as the primary CLI pipeline. Resolve its version at most once per process; raw
    /// version output is never surfaced if the command is unavailable or malformed.
    private static let cachedCreditsUserAgent: String = {
        guard let data = try? runClaude(arguments: ["--version"], timeout: authTimeout),
              let output = String(data: data, encoding: .utf8),
              let match = output.range(of: #"[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?"#,
                                       options: .regularExpression) else {
            return "claude-code/2.1.224"
        }
        return "claude-code/\(output[match])"
    }()

    static func creditsUserAgent() -> String {
        cachedCreditsUserAgent
    }

    /// Fetch auth metadata and usage through Claude Code. On failure, retain the previous values
    /// and mark them stale; first-run failures return an explicit no-data snapshot.
    public static func fetchSnapshot(previous: UsageSnapshot? = nil) async -> UsageSnapshot {
        let result: Result<UsageSnapshot, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Result { try fetchFromClaude() })
            }
        }

        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            return staleSnapshot(previous: previous, message: safeMessage(for: error))
        }
    }

    private static func fetchFromClaude() throws -> UsageSnapshot {
        var email: String?
        var subscriptionType: String?

        // Auth metadata is advisory: an explicit logged-out response stops the pipeline, while an
        // unavailable or malformed status response must not prevent `/usage` from being attempted.
        if let data = try? runClaude(arguments: ["auth", "status", "--json"], timeout: authTimeout),
           let status = try? UsageParser.parseAuthStatus(data) {
            guard status.loggedIn else { throw UsageClientError.signedOut }
            email = status.email
            subscriptionType = status.subscriptionType
        }

        let data = try runClaude(
            arguments: ["-p", "/usage", "--output-format", "json", "--strict-mcp-config", "--no-session-persistence"],
            timeout: usageTimeout
        )
        let fetchedAt = Date()
        return try UsageParser.parse(data,
                                     planLabel: planLabel(subscriptionType: subscriptionType),
                                     email: email,
                                     now: fetchedAt,
                                     fetchedAt: fetchedAt)
    }

    private static func staleSnapshot(previous: UsageSnapshot?, message: String) -> UsageSnapshot {
        guard var previous else { return .noData(error: message) }
        previous.stale = true
        previous.error = message
        return previous
    }

    private static func safeMessage(for error: Error) -> String {
        guard let clientError = error as? UsageClientError else {
            return "Claude couldn't return usage. Try again."
        }
        switch clientError {
        case .claudeNotFound:
            return "Claude Code CLI not found. Install Claude Code, then refresh."
        case .timedOut:
            return "Claude took too long to return usage. Try again."
        case .signedOut:
            return "Sign in with `claude`, then refresh."
        case .unusableOutput:
            return "Claude couldn't return usage. Try again."
        }
    }

    /// Run one bounded CLI call with no inherited stdin or stderr. Stdout is retained only long
    /// enough for the narrow decoders above; it is never logged or used in user-facing errors.
    private static func runClaude(arguments: [String], timeout: TimeInterval) throws -> Data {
        guard let executable = claudeExecutable() else { throw UsageClientError.claudeNotFound }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = claudeEnvironment()

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UsageClientError.unusableOutput
        }

        let deadline = Date().addingTimeInterval(timeout)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
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

        // Claude is non-interactive for both commands; close stdin immediately so it can never
        // wait for input from the menu-bar process.
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.isRunning { process.waitUntilExit() }

        if Date() >= deadline { throw UsageClientError.timedOut }
        // `claude auth status --json` exits 1 when signed out while still returning its valid JSON
        // object. A nonzero status therefore cannot by itself make structured stdout unusable; the
        // narrow decoders decide whether nonempty output satisfies their contract.
        guard !data.isEmpty else { throw UsageClientError.unusableOutput }
        return data
    }

    private static func claudeExecutable() -> URL? {
        let source = ProcessInfo.processInfo.environment
        let home = homePath(source: source)
        var candidates: [String] = []
        if let override = source["CLAUDE_BIN"], !override.isEmpty { candidates.append(override) }
        candidates += fixedDiscoveryDirectories(home: home).map { "\($0)/claude" }
        for directory in pathDirectories(source["PATH"]) {
            candidates.append("\(directory)/claude")
        }

        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func claudeEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        // Do not forward arbitrary API keys or unrelated process secrets into the child.
        let allowedKeys = [
            "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "SSL_CERT_FILE", "SSL_CERT_DIR",
        ]
        for key in allowedKeys {
            if let value = source[key] { environment[key] = value }
        }

        let home = homePath(source: source)
        environment["HOME"] = source["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home
        environment["TMPDIR"] = source["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()

        var directories = fixedDiscoveryDirectories(home: home)
        directories += pathDirectories(source["PATH"])
        directories += ["/usr/bin", "/bin"]
        environment["PATH"] = unique(directories).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    private static func fixedDiscoveryDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    private static func pathDirectories(_ path: String?) -> [String] {
        (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func homePath(source: [String: String]) -> String {
        if let value = source["HOME"], !value.isEmpty { return value }
        if let password = getpwuid(getuid()), let directory = password.pointee.pw_dir {
            return String(cString: directory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
