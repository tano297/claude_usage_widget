import Foundation
import CryptoKit
import Security
#if canImport(ClaudeUsageCore)
import ClaudeUsageCore
#endif

// Browser sign-in and the usage read follow Usage4Claude (MIT, Copyright 2026 f-is-h):
// https://github.com/f-is-h/Usage4Claude
// Same public Claude Code OAuth client, PKCE, and GET /api/oauth/usage. This file does not route
// inference. The refresh token goes to RosterSessionStore. Access tokens stay in memory only.
// The URLSession is injected so tests can stub responses; the app uses `RosterAPI.live`.

public enum RosterOAuth {
    public static let authorizeURL = "https://claude.ai/oauth/authorize"
    public static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    public static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    public static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Read-only. Inference scope is not requested.
    public static let scope = "user:profile"
    public static let betaHeader = "oauth-2025-04-20"
    public static let ports: [UInt16] = [1456, 1458]
    public static let callbackPath = "/callback"

    public static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }
}

/// Which request failed, for the log line.
public enum RosterStage: String, Sendable, Equatable {
    case token
    case usage
    case profile
}

/// What a failed request said, without any token or body text. `oauthError` is only the short
/// OAuth error code (for example `invalid_grant`), checked to be a plain identifier.
public struct RosterFailure: Sendable, Equatable {
    public var stage: RosterStage
    public var status: Int?
    public var oauthError: String?

    public init(stage: RosterStage, status: Int?, oauthError: String? = nil) {
        self.stage = stage
        self.status = status
        self.oauthError = oauthError
    }

    public var isInvalidGrant: Bool { oauthError == "invalid_grant" }

    /// The token endpoint refused this refresh token for good: 401, or 400 `invalid_grant`.
    public var revokesSignIn: Bool {
        stage == .token && (status == 401 || isInvalidGrant)
    }
}

public enum RosterAPIError: Error, Equatable {
    /// A dead refresh token at the token endpoint, or a 401 from a read.
    case signedOut(RosterFailure)
    case noEmail
    case noLimits
    /// Network failure (status nil), or a status that does not mean sign-out.
    case unreachable(RosterFailure)
}

public struct RosterTokens: Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// A minute before the access token expires. Nil when the response did not say.
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// The OAuth `error` code of a failed response, when it is a short plain identifier. Bodies are
/// never logged or kept: this returns only that code. Both the OAuth shape
/// (`{"error":"invalid_grant"}`) and Anthropic's API shape (`{"error":{"type":"..."}}`) are read.
public enum RosterOAuthErrorCode {
    public static func parse(_ body: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let code = json["error"] as? String, let clean = sanitize(code) { return clean }
            if let nested = json["error"] as? [String: Any],
               let code = nested["type"] as? String,
               let clean = sanitize(code) { return clean }
        }
        // A body that is not JSON but names the grant error still counts, as before.
        if let text = String(data: body, encoding: .utf8), text.contains("invalid_grant") {
            return "invalid_grant"
        }
        return nil
    }

    private static func sanitize(_ code: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !code.isEmpty, code.count <= 64,
              code.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return code
    }
}

public struct RosterAPI {
    public let session: URLSession
    public let now: @Sendable () -> Date

    public init(session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// Redirects are refused, so a bearer token never follows one to another address.
    public static let live: RosterAPI = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return RosterAPI(session: URLSession(configuration: config,
                                             delegate: NoRedirectSessionDelegate.shared,
                                             delegateQueue: nil))
    }()

    public func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> RosterTokens {
        try await token(payload: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "client_id": RosterOAuth.clientID,
            "code_verifier": verifier
        ])
    }

    public func refresh(_ refreshToken: String) async throws -> RosterTokens {
        try await token(payload: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": RosterOAuth.clientID
        ])
    }

    /// Email only. Organization fields in the profile payload are discarded.
    public func profileEmail(accessToken: String) async throws -> String {
        let data = try await get(RosterOAuth.profileURL, stage: .profile, accessToken: accessToken)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let email = account["email"] as? String,
              email.contains("@") else {
            throw RosterAPIError.noEmail
        }
        return email
    }

    public func usage(accessToken: String) async throws -> (fiveHour: LimitBar?, week: LimitBar?) {
        let data = try await get(RosterOAuth.usageURL, stage: .usage, accessToken: accessToken)
        do {
            return try RosterUsageParser.parse(data)
        } catch {
            throw RosterAPIError.noLimits
        }
    }

    private func token(payload: [String: String]) async throws -> RosterTokens {
        guard let url = URL(string: RosterOAuth.tokenURL),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RosterAPIError.unreachable(RosterFailure(stage: .token, status: nil))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await send(request, stage: .token)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // A dead grant is 401, or 400 invalid_grant. Any other 400 is a request problem:
            // the saved refresh token may still be good, so it must not look like a sign-out.
            let failure = RosterFailure(stage: .token, status: status, oauthError: RosterOAuthErrorCode.parse(data))
            throw failure.revokesSignIn ? RosterAPIError.signedOut(failure) : RosterAPIError.unreachable(failure)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw RosterAPIError.unreachable(RosterFailure(stage: .token, status: status, oauthError: "unreadable_response"))
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue
        let issuedAt = now()
        return RosterTokens(accessToken: access,
                            refreshToken: json["refresh_token"] as? String ?? "",
                            expiresAt: lifetime.map { issuedAt.addingTimeInterval($0 - 60) })
    }

    private func get(_ urlString: String, stage: RosterStage, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw RosterAPIError.unreachable(RosterFailure(stage: stage, status: nil))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(RosterOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await send(request, stage: stage)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let failure = RosterFailure(stage: stage, status: status, oauthError: RosterOAuthErrorCode.parse(data))
            throw status == 401 ? RosterAPIError.signedOut(failure) : RosterAPIError.unreachable(failure)
        }
        return data
    }

    private func send(_ request: URLRequest, stage: RosterStage) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw RosterAPIError.unreachable(RosterFailure(stage: stage, status: nil, oauthError: "network"))
        }
    }
}

struct RosterPKCE {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = Self.random(byteCount: 64)
        state = Self.random(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Self.base64URL(Data(digest))
    }

    private static func random(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
