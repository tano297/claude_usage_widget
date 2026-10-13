import AppKit
import Foundation
import Network

// Localhost callback and the browser handoff follow Usage4Claude (MIT, Copyright 2026 f-is-h):
// https://github.com/f-is-h/Usage4Claude
// One OAuth redirect is accepted, a short HTML page is returned, and favicon is ignored.
// The listener binds to loopback only. Refresh tokens are not handled here.

/// Where the sign-in page opened.
enum RosterBrowserWindow {
    case privateChrome
    case chromeProfile(String)
    case defaultBrowser
}

/// A Chrome profile folder and the name Chrome shows for it.
struct ChromeProfile: Identifiable, Hashable {
    let directory: String
    let name: String
    var id: String { directory }
}

/// Where each sign-in opens: a private Chrome window, unless a Chrome profile is chosen in the
/// Subscriptions window. A profile keeps its saved logins. A private window starts signed out.
enum RosterBrowser {
    static let profileKey = "rosterChromeProfile"
    static let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    static var hasChrome: Bool {
        FileManager.default.isExecutableFile(atPath: chromeBinary)
    }

    /// Profile folders and display names from Chrome's `Local State`. Only the names are read.
    static func chromeProfiles() -> [ChromeProfile] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.map { directory, value in
            let name = ((value as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChromeProfile(directory: directory, name: name ?? directory)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The chosen profile while Chrome still has it. Nil means a private window.
    static func chosenProfile() -> ChromeProfile? {
        guard let directory = UserDefaults.standard.string(forKey: profileKey), !directory.isEmpty else {
            return nil
        }
        return chromeProfiles().first { $0.directory == directory }
    }
}

/// Opens the browser for one Claude sign-in and waits for the redirect.
@MainActor
final class RosterLogin {
    private let server = RosterCallbackServer()
    private var pkce: RosterPKCE?
    private var redirectURI = ""
    private var onCode: ((String, String, String, String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var waiting = false

    /// Where the sign-in page opened. `nil` when sign-in did not start: `onFailure` has already
    /// been called, or the sign-in was cancelled while the listener started.
    func start(
        onCode: @escaping (String, String, String, String) -> Void,
        onFailure: @escaping (String) -> Void
    ) async -> RosterBrowserWindow? {
        cancel()
        finished = false
        waiting = false
        self.onCode = onCode
        self.onFailure = onFailure

        let pkce = RosterPKCE()
        self.pkce = pkce
        let port = await server.start(ports: RosterOAuth.ports, expectedState: pkce.state, onCallback: { [weak self] query in
            Task { @MainActor in self?.handle(query) }
        })
        // A cancel can land while the listener starts. Then the listener closes and nothing opens.
        guard !finished, self.pkce?.state == pkce.state else {
            if self.pkce == nil { server.stop() }
            return nil
        }
        guard let port else {
            fail("Couldn't open the sign-in listener. Try again.")
            return nil
        }
        redirectURI = RosterOAuth.redirectURI(port: port)
        guard let url = Self.authorizeURL(pkce: pkce, redirectURI: redirectURI) else {
            fail("Couldn't open the sign-in page. Try again.")
            return nil
        }
        guard let window = open(url) else {
            fail("Couldn't open a browser. Try again.")
            return nil
        }
        waiting = true
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.failIfPending("Sign-in timed out. Try again.")
        }
        return window
    }

    /// Accepts the callback address when the browser never reaches this Mac's listener.
    /// Text that is not this sign-in's address returns false, and the sign-in keeps waiting.
    @discardableResult
    func submitManual(_ pasted: String) -> Bool {
        guard waiting, !finished, let pkce else { return false }
        let query = Self.parseManualCallback(pasted)
        guard query["code"] != nil || query["error"] != nil, query["state"] == pkce.state else { return false }
        handle(query)
        return true
    }

    func cancel() {
        finished = true
        waiting = false
        timeoutTask?.cancel()
        timeoutTask = nil
        server.stop()
        onCode = nil
        onFailure = nil
        pkce = nil
    }

    /// Full callback URL, or `code#state`. Query values win when the text is a URL.
    /// A bare code has no state, so it returns nothing.
    static func parseManualCallback(_ raw: String) -> [String: String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        if let items = URLComponents(string: text)?.queryItems, !items.isEmpty {
            var result: [String: String] = [:]
            for key in ["code", "state", "error"] {
                if let value = items.first(where: { $0.name == key })?.value, !value.isEmpty {
                    result[key] = value
                }
            }
            return result
        }
        if text.contains("#"), !text.contains("?"), !text.contains("/") {
            let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return [:] }
            return ["code": parts[0], "state": parts[1]]
        }
        return [:]
    }

    private func handle(_ query: [String: String]) {
        guard !finished, let pkce else { return }
        // The listener and the paste box check state first. A mismatch here is ignored.
        guard query["state"] == pkce.state else { return }
        if query["error"] != nil {
            fail("Sign-in was cancelled.")
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            fail("Sign-in didn't return a code. Try again.")
            return
        }
        let verifier = pkce.verifier
        let state = pkce.state
        let redirectURI = self.redirectURI
        finished = true
        waiting = false
        timeoutTask?.cancel()
        timeoutTask = nil
        server.stop()
        onCode?(code, verifier, state, redirectURI)
    }

    private func failIfPending(_ message: String) {
        guard !finished else { return }
        fail(message)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        waiting = false
        timeoutTask?.cancel()
        timeoutTask = nil
        server.stop()
        let report = onFailure
        onCode = nil
        onFailure = nil
        report?(message)
    }

    private static func authorizeURL(pkce: RosterPKCE, redirectURI: String) -> URL? {
        var comps = URLComponents(string: RosterOAuth.authorizeURL)
        comps?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: RosterOAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: RosterOAuth.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return comps?.url
    }

    /// Chrome in a private window, or in the chosen profile. `open -na` is avoided: it starts a
    /// second Chrome. Without Chrome, the default browser. Nil when nothing opened.
    private func open(_ url: URL) -> RosterBrowserWindow? {
        if RosterBrowser.hasChrome {
            let profile = RosterBrowser.chosenProfile()
            let arguments = profile.map { ["--profile-directory=\($0.directory)", "--new-window", url.absoluteString] }
                ?? ["--incognito", url.absoluteString]
            if launch(RosterBrowser.chromeBinary, arguments: arguments) {
                return profile.map { .chromeProfile($0.name) } ?? .privateChrome
            }
        }
        return NSWorkspace.shared.open(url) ? .defaultBrowser : nil
    }

    private func launch(_ binary: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Keep the Process alive until Chrome exits, or a short-lived handoff becomes a zombie.
        process.terminationHandler = { [process] _ in _ = process }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

/// Listens on 127.0.0.1, and on ::1 when that binds too. Only `GET /callback` with this sign-in's
/// state is delivered, and only once. Anything else gets 404 and the sign-in keeps waiting.
private final class RosterCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.claudeusage.app.roster.callback")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var onCallback: (([String: String]) -> Void)?
    private var expectedState = ""
    private var didDeliver = false

    func start(ports: [UInt16],
               expectedState: String,
               onCallback: @escaping ([String: String]) -> Void) async -> UInt16? {
        stop()
        lock.lock()
        didDeliver = false
        self.expectedState = expectedState
        self.onCallback = onCallback
        lock.unlock()
        for port in ports {
            // IPv4 is required. A browser that reaches `localhost` on 127.0.0.1 must find this
            // listener, not another process that holds the port.
            let v4 = await listen(host: "127.0.0.1", port: port)
            _ = await listen(host: "::1", port: port)
            if v4 { return port }
            dropListeners()
        }
        return nil
    }

    func stop() {
        lock.lock()
        onCallback = nil
        lock.unlock()
        dropListeners()
    }

    private func dropListeners() {
        lock.lock()
        let current = listeners
        listeners = []
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    private func listen(host hostName: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostName), port: nwPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            return false
        }
        return await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.first {
                        self.keep(listener)
                        continuation.resume(returning: true)
                    }
                case .waiting, .failed, .cancelled:
                    gate.first {
                        listener.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                // A client that sends nothing is closed, so no connection outlives the sign-in.
                self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                gate.first {
                    listener.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func keep(_ listener: NWListener) {
        lock.lock()
        listeners.append(listener)
        lock.unlock()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            let text = String(data: next, encoding: .utf8) ?? ""
            let headersEnded = text.contains("\r\n\r\n")
            if !headersEnded, !isComplete, error == nil, next.count < 65_536 {
                self.receive(connection, buffer: next)
                return
            }
            self.reply(connection, request: text)
        }
    }

    private func reply(_ connection: NWConnection, request: String) {
        let (method, path, query) = Self.parseRequest(request)
        lock.lock()
        let state = expectedState
        lock.unlock()
        let isCallback = method == "GET"
            && path == RosterOAuth.callbackPath
            && !state.isEmpty && query["state"] == state
            && (query["code"] != nil || query["error"] != nil)
        let body = isCallback ? Self.page(success: query["code"] != nil) : Self.notFoundPage()
        let status = isCallback ? "200 OK" : "404 Not Found"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(Data(body.utf8))
        connection.send(content: bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
        guard isCallback else { return }
        lock.lock()
        let deliver = !didDeliver
        if deliver { didDeliver = true }
        let callback = onCallback
        lock.unlock()
        guard deliver else { return }
        DispatchQueue.main.async { callback?(query) }
    }

    /// Method, path, and query of the request line.
    private static func parseRequest(_ request: String) -> (method: String, path: String, query: [String: String]) {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return ("", "", [:]) }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("", "", [:]) }
        let method = String(parts[0])
        let target = parts[1]
        guard let qIndex = target.firstIndex(of: "?") else { return (method, String(target), [:]) }
        let path = String(target[..<qIndex])
        let queryString = target[target.index(after: qIndex)...]
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let name = String(key).removingPercentEncoding ?? String(key)
            let rawValue = kv.count > 1 ? String(kv[1]) : ""
            result[name] = rawValue.removingPercentEncoding ?? rawValue
        }
        return (method, path, result)
    }

    private static func page(success: Bool) -> String {
        let heading = success ? "Signed in" : "Sign-in failed"
        let message = success
            ? "You can close this tab and return to Claude Usage."
            : "Return to Claude Usage and try again."
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(heading)</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;text-align:center;padding-top:80px;color:#1d1d1f;background:#f5f5f7">
        <h2>\(heading)</h2>
        <p>\(message)</p>
        </body></html>
        """
    }

    private static func notFoundPage() -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Not Found</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;text-align:center;padding-top:80px">
        <h2>Not Found</h2>
        </body></html>
        """
    }
}

/// Resumes a continuation once when the listener queue and the timeout race.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first(_ body: () -> Void) {
        lock.lock()
        let run = !done
        if run { done = true }
        lock.unlock()
        if run { body() }
    }
}
