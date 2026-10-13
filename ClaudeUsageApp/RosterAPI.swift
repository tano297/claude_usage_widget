import Foundation
import CryptoKit
import Security

// Browser sign-in and the usage read follow Usage4Claude (MIT, Copyright 2026 f-is-h):
// https://github.com/f-is-h/Usage4Claude
// Same public Claude Code OAuth client, PKCE, and GET /api/oauth/usage. This file does not route
// inference. The refresh token goes to RosterSessionStore. Access tokens stay in memory only.

enum RosterOAuth {
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Read-only. Inference scope is not requested.
    static let scope = "user:profile"
    static let betaHeader = "oauth-2025-04-20"
    static let ports: [UInt16] = [1456, 1458]
    static let callbackPath = "/callback"

    static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }
}

enum RosterAPIError: Error {
    case signedOut
    case noEmail
    case noLimits
    case unreachable
}

struct RosterTokens {
    var accessToken: String
    var refreshToken: String
    /// A minute before the access token expires. Nil when the response did not say.
    var expiresAt: Date?
}

enum RosterAPI {
    /// Redirects are refused, so a bearer token never follows one to another address.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoRedirectSessionDelegate.shared, delegateQueue: nil)
    }()

    static func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> RosterTokens {
        try await token(payload: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "client_id": RosterOAuth.clientID,
            "code_verifier": verifier
        ])
    }

    static func refresh(_ refreshToken: String) async throws -> RosterTokens {
        try await token(payload: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": RosterOAuth.clientID
        ])
    }

    /// Email only. Organization fields in the profile payload are discarded.
    static func profileEmail(accessToken: String) async throws -> String {
        let data = try await get(RosterOAuth.profileURL, accessToken: accessToken)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let email = account["email"] as? String,
              email.contains("@") else {
            throw RosterAPIError.noEmail
        }
        return email
    }

    static func usage(accessToken: String) async throws -> (fiveHour: LimitBar?, week: LimitBar?) {
        let data = try await get(RosterOAuth.usageURL, accessToken: accessToken)
        do {
            return try RosterUsageParser.parse(data)
        } catch {
            throw RosterAPIError.noLimits
        }
    }

    private static func token(payload: [String: String]) async throws -> RosterTokens {
        guard let url = URL(string: RosterOAuth.tokenURL),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RosterAPIError.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // A dead grant is 401, or 400 invalid_grant. Any other 400 is a request problem:
            // the saved refresh token may still be good, so it must not look like a sign-out.
            throw Self.isDeadGrant(status: status, body: data) ? RosterAPIError.signedOut : RosterAPIError.unreachable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw RosterAPIError.unreachable
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue
        return RosterTokens(accessToken: access,
                            refreshToken: json["refresh_token"] as? String ?? "",
                            expiresAt: lifetime.map { Date().addingTimeInterval($0 - 60) })
    }

    private static func get(_ urlString: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw RosterAPIError.unreachable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(RosterOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw RosterAPIError.signedOut }
        guard (200...299).contains(status) else { throw RosterAPIError.unreachable }
        return data
    }

    /// True when the token endpoint says this refresh token will not work again.
    /// The body is not stored, logged, or copied into the error.
    private static func isDeadGrant(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        guard status == 400, let text = String(data: body, encoding: .utf8) else { return false }
        return text.contains("invalid_grant")
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw RosterAPIError.unreachable
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
