import Foundation
import os
#if canImport(ClaudeUsageCore)
import ClaudeUsageCore
#endif

// One roster account's read: refresh token -> access token -> usage. No WidgetKit and no Keychain
// calls here; the token store is injected, so this file also builds in the Swift package and its
// checks run against a stubbed URLSession and an in-memory store (Tools/DataLayerCheck).

/// What the token store returned for one account. `savedAt` is when the item was last written,
/// used only for the age in the log line.
public enum RosterTokenLoad: Equatable {
    case token(String, savedAt: Date?)
    case missing
    case unavailable
}

/// Where refresh tokens live. The app passes the Keychain store; checks pass a fake.
public protocol RosterTokenStore {
    func load(id: UUID) -> RosterTokenLoad
    /// False when the write did not happen (for example a locked keychain).
    func save(id: UUID, email: String, refreshToken: String) -> Bool
}

/// Fixed row texts. Other tools match on "Sign in again", so every sign-out text keeps those words.
public enum RosterText {
    public static let revoked = "Signed out by a newer sign-in to this account. Sign in again."
    public static let signIn = "Sign in again."
    public static let saveFailed = "Couldn't save sign-in (Keychain locked?)"
    public static let keychainBlocked = "Keychain locked or blocked. Unlock, or add again."
    public static let unreadable = "Couldn't read usage."
}

/// One log line per failed roster request. Only the roster UUID, the stage, the HTTP status, the
/// short OAuth error code, the refresh token's age, and what the agent did. Never a token, cookie,
/// email, or body.
public enum RosterLog {
    private static let logger = Logger(subsystem: "com.claudeusage.app", category: "roster")

    /// Writes at the default level, so the line stays in the unified log after the debug buffer is
    /// purged: `log show --predicate 'subsystem == "com.claudeusage.app"' --info`.
    public static let system: (String) -> Void = { line in
        logger.log("\(line, privacy: .public)")
    }

    public static func line(id: UUID,
                            failure: RosterFailure?,
                            tokenAge: TimeInterval?,
                            action: String) -> String {
        let stage = failure?.stage.rawValue ?? "keychain"
        let status = failure?.status.map(String.init) ?? "none"
        let code = failure?.oauthError ?? "none"
        return "roster account=\(id.uuidString) stage=\(stage) status=\(status) error=\(code) "
            + "tokenAge=\(age(tokenAge)) action=\(action)"
    }

    public static func age(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return "unknown" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }
}

/// Reads each roster account. Keeps access tokens in memory until a minute before they expire, and
/// keeps a rotated refresh token in memory when the Keychain refused to save it, so it is not lost.
@MainActor
public final class RosterSync {
    public let api: RosterAPI
    private let store: RosterTokenStore
    private let now: () -> Date
    private let log: (String) -> Void

    /// Access tokens, each until a minute before it expires. Never written to disk.
    private var accessTokens: [UUID: (token: String, expiresAt: Date)] = [:]
    /// Rotated refresh tokens the Keychain did not accept yet, with the time they were issued. The
    /// next cycle saves them again before anything else and refreshes with them, not with the spent
    /// token still in the Keychain.
    private var unsaved: [UUID: (token: String, since: Date)] = [:]

    public init(api: RosterAPI,
                store: RosterTokenStore,
                now: @escaping () -> Date = { Date() },
                log: @escaping (String) -> Void = RosterLog.system) {
        self.api = api
        self.store = store
        self.now = now
        self.log = log
    }

    public func hasUnsavedRefreshToken(for id: UUID) -> Bool { unsaved[id] != nil }

    /// Drops what is held in memory for an account that was removed.
    public func forget(_ id: UUID) {
        accessTokens[id] = nil
        unsaved[id] = nil
    }

    /// A new sign-in saved its own refresh token. Older in-memory state for the account is dropped.
    public func adoptSignIn(id: UUID, tokens: RosterTokens) {
        unsaved[id] = nil
        if let expiresAt = tokens.expiresAt {
            accessTokens[id] = (tokens.accessToken, expiresAt)
        } else {
            accessTokens[id] = nil
        }
    }

    /// One account's next row. An account the token endpoint already refused (`signedOut`) is
    /// returned as it is, with no request, until a new sign-in clears the flag.
    public func update(_ account: RosterAccount) async -> RosterAccount {
        var row = account
        let id = row.id
        if row.signedOut == true { return row }

        // A rotated token the Keychain refused last time: try the save again first.
        if let pending = unsaved[id] {
            if store.save(id: id, email: row.email, refreshToken: pending.token) {
                unsaved[id] = nil
            } else {
                log(RosterLog.line(id: id, failure: nil, tokenAge: now().timeIntervalSince(pending.since),
                                   action: "save-retry-failed"))
            }
        }

        let refreshToken: String
        let tokenAge: TimeInterval?
        let fromKeychain: Bool
        if let pending = unsaved[id] {
            refreshToken = pending.token
            tokenAge = now().timeIntervalSince(pending.since)
            fromKeychain = false
        } else {
            switch store.load(id: id) {
            case .missing:
                accessTokens[id] = nil
                row.stale = true
                row.error = RosterText.signIn
                log(RosterLog.line(id: id, failure: nil, tokenAge: nil, action: "no-keychain-item"))
                return row
            case .unavailable:
                accessTokens[id] = nil
                row.stale = true
                // Locked keychain, or an item from a differently signed build. The token may be fine.
                row.error = RosterText.keychainBlocked
                log(RosterLog.line(id: id, failure: nil, tokenAge: nil, action: "keychain-unavailable"))
                return row
            case .token(let token, let savedAt):
                refreshToken = token
                tokenAge = savedAt.map { now().timeIntervalSince($0) }
                fromKeychain = true
            }
        }

        do {
            let meters = try await readMeters(row, refreshToken: refreshToken,
                                              tokenAge: tokenAge, fromKeychain: fromKeychain)
            row.fiveHour = meters.fiveHour
            row.week = meters.week
            row.fetchedAt = now()
            row.stale = false
            row.error = unsaved[id] == nil ? nil : RosterText.saveFailed
        } catch RosterAPIError.signedOut(let failure) {
            row.stale = true
            if failure.revokesSignIn {
                // The token endpoint will not take this refresh token again. Stop asking.
                accessTokens[id] = nil
                unsaved[id] = nil
                row.signedOut = true
                row.error = failure.isInvalidGrant ? RosterText.revoked : RosterText.signIn
                log(RosterLog.line(id: id, failure: failure, tokenAge: tokenAge, action: "signed-out-stop"))
            } else {
                // A 401 on a read just after a refresh. Why is unknown; the next cycle tries again.
                row.error = RosterText.signIn
                log(RosterLog.line(id: id, failure: failure, tokenAge: tokenAge, action: "read-401"))
            }
        } catch RosterAPIError.unreachable(let failure) {
            row.stale = true
            row.error = unsaved[id] == nil ? RosterText.unreadable : RosterText.saveFailed
            log(RosterLog.line(id: id, failure: failure, tokenAge: tokenAge, action: "retry-next-cycle"))
        } catch {
            row.stale = true
            row.error = unsaved[id] == nil ? RosterText.unreadable : RosterText.saveFailed
            log(RosterLog.line(id: id, failure: RosterFailure(stage: .usage, status: 200, oauthError: "no_limits"),
                               tokenAge: tokenAge, action: "retry-next-cycle"))
        }
        return row
    }

    /// A cached access token is used while it lasts. Otherwise the refresh token is spent, and the
    /// one that replaces it is saved (or held in memory) before the usage read.
    private func readMeters(_ row: RosterAccount,
                            refreshToken: String,
                            tokenAge: TimeInterval?,
                            fromKeychain: Bool) async throws -> (fiveHour: LimitBar?, week: LimitBar?) {
        let id = row.id
        if let cached = accessTokens[id], cached.expiresAt > now() {
            do {
                return try await api.usage(accessToken: cached.token)
            } catch RosterAPIError.signedOut(let failure) {
                accessTokens[id] = nil
                log(RosterLog.line(id: id, failure: failure, tokenAge: tokenAge, action: "drop-access-token"))
            }
        }
        var spent = refreshToken
        let tokens: RosterTokens
        do {
            tokens = try await api.refresh(refreshToken)
        } catch RosterAPIError.signedOut(let failure) where failure.revokesSignIn && fromKeychain {
            // Another writer may have rotated the Keychain item while this request was out. Read it
            // once more; only a different token earns one more try.
            guard case .token(let fresh, _) = store.load(id: id), fresh != refreshToken else { throw RosterAPIError.signedOut(failure) }
            log(RosterLog.line(id: id, failure: failure, tokenAge: tokenAge, action: "keychain-changed-retry"))
            spent = fresh
            tokens = try await api.refresh(fresh)
        }
        keep(tokens, for: row, replacing: spent)
        return try await api.usage(accessToken: tokens.accessToken)
    }

    /// Saves a rotated refresh token. When the save fails the token stays in memory, the next cycle
    /// saves it again, and the row says so, instead of losing the only valid token.
    private func keep(_ tokens: RosterTokens, for row: RosterAccount, replacing previous: String) {
        let id = row.id
        if !tokens.refreshToken.isEmpty, tokens.refreshToken != previous {
            if store.save(id: id, email: row.email, refreshToken: tokens.refreshToken) {
                unsaved[id] = nil
            } else {
                unsaved[id] = (tokens.refreshToken, now())
                log(RosterLog.line(id: id, failure: nil, tokenAge: 0, action: "save-failed-kept-in-memory"))
            }
        }
        if let expiresAt = tokens.expiresAt {
            accessTokens[id] = (tokens.accessToken, expiresAt)
        }
    }
}
