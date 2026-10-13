import Combine
import Foundation
import WidgetKit

/// Extra subscriptions. This type never reads or writes the Claude CLI snapshot.
/// A miss here leaves `usage.json` unchanged.
@MainActor
final class RosterController: ObservableObject {
    @Published private(set) var accounts: [RosterAccount] = []
    @Published private(set) var isSigningIn = false
    @Published private(set) var canPaste = false
    @Published private(set) var signInNote: String?
    @Published var pastedCallback = ""

    private let login = RosterLogin()
    /// Bumps on sign-in, cancel, and remove so an in-flight refresh cannot write over them.
    private var generation = 0
    /// Access tokens in memory only, each until a minute before it expires. Never written to disk.
    private var accessTokens: [UUID: (token: String, expiresAt: Date)] = [:]

    init() {
        accounts = RosterStore.load().accounts
    }

    func refresh() async {
        guard !isSigningIn else { return }
        let epoch = generation
        var next = accounts
        for index in next.indices {
            if generation != epoch || isSigningIn { return }
            let id = next[index].id
            switch RosterSessionStore.load(id: id) {
            case .missing:
                accessTokens[id] = nil
                next[index].stale = true
                next[index].error = "Sign in again."
            case .unavailable:
                accessTokens[id] = nil
                next[index].stale = true
                // Locked keychain, or an item from a differently signed build. The token may be fine.
                next[index].error = "Keychain locked or blocked. Unlock, or add again."
            case .token(let token):
                do {
                    let meters = try await readMeters(id: id, refreshToken: token)
                    if generation != epoch || isSigningIn { return }
                    next[index].fiveHour = meters.fiveHour
                    next[index].week = meters.week
                    next[index].fetchedAt = Date()
                    next[index].stale = false
                    next[index].error = nil
                } catch RosterAPIError.signedOut {
                    next[index].stale = true
                    next[index].error = "Sign in again."
                } catch {
                    next[index].stale = true
                    next[index].error = "Couldn't read usage."
                }
            }
        }
        guard generation == epoch, !isSigningIn else { return }
        accounts = next
        try? RosterStore.save(RosterSnapshot(accounts: accounts))
    }

    func beginSignIn() {
        guard !isSigningIn else { return }
        generation += 1
        let epoch = generation
        isSigningIn = true
        canPaste = false
        signInNote = "Opening the browser…"
        pastedCallback = ""
        Task {
            let window = await login.start(
                onCode: { [weak self] code, verifier, state, redirectURI in
                    Task { await self?.finish(epoch: epoch, code: code, verifier: verifier, state: state, redirectURI: redirectURI) }
                },
                onFailure: { [weak self] message in
                    self?.failSignIn(message)
                }
            )
            guard let window, generation == epoch, isSigningIn else { return }
            canPaste = true
            switch window {
            case .privateChrome:
                signInNote = "A private Chrome window is open. Log into one account."
            case .chromeProfile(let name):
                signInNote = "Chrome is open in the \(name) profile. Log into one account."
            case .defaultBrowser:
                signInNote = "Chrome isn't installed. The default browser opened."
            }
        }
    }

    func submitPasted() {
        guard login.submitManual(pastedCallback) else {
            signInNote = "Paste the full localhost address from the browser."
            return
        }
        canPaste = false
    }

    func cancelSignIn() {
        generation += 1
        login.cancel()
        isSigningIn = false
        canPaste = false
        signInNote = nil
        pastedCallback = ""
    }

    func remove(_ account: RosterAccount) {
        guard !isSigningIn else { return }
        generation += 1
        RosterSessionStore.delete(id: account.id)
        accessTokens[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        try? RosterStore.save(RosterSnapshot(accounts: accounts))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.accounts)
    }

    /// Both windows for one account. A cached access token is used while it lasts. Otherwise the
    /// refresh token is spent, and the one that replaces it is saved before the usage read.
    private func readMeters(id: UUID, refreshToken: String) async throws -> (fiveHour: LimitBar?, week: LimitBar?) {
        if let cached = accessTokens[id], cached.expiresAt > Date() {
            do {
                return try await RosterAPI.usage(accessToken: cached.token)
            } catch RosterAPIError.signedOut {
                accessTokens[id] = nil
            }
        }
        let tokens = try await RosterAPI.refresh(refreshToken)
        keep(tokens, for: id, replacing: refreshToken)
        return try await RosterAPI.usage(accessToken: tokens.accessToken)
    }

    /// Saves a rotated refresh token and caches the access token, unless the account was removed
    /// while the request was out. The UI generation is not checked: a dropped rotation signs out.
    private func keep(_ tokens: RosterTokens, for id: UUID, replacing previous: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if !tokens.refreshToken.isEmpty, tokens.refreshToken != previous {
            RosterSessionStore.save(id: id, email: account.email, refreshToken: tokens.refreshToken)
        }
        if let expiresAt = tokens.expiresAt {
            accessTokens[id] = (tokens.accessToken, expiresAt)
        }
    }

    private func finish(epoch: Int, code: String, verifier: String, state: String, redirectURI: String) async {
        guard generation == epoch else { return }
        signInNote = "Reading that account…"
        canPaste = false
        let tokens: RosterTokens
        let email: String
        do {
            tokens = try await RosterAPI.exchange(code: code, state: state, verifier: verifier, redirectURI: redirectURI)
            guard !tokens.refreshToken.isEmpty else {
                failSignIn("Sign-in didn't return a session. Try again.")
                return
            }
            guard generation == epoch else { return }
            email = try await RosterAPI.profileEmail(accessToken: tokens.accessToken)
        } catch RosterAPIError.noEmail {
            failSignIn("That account didn't return an email. Try again.")
            return
        } catch RosterAPIError.signedOut {
            failSignIn("Sign-in didn't complete. Try again.")
            return
        } catch {
            failSignIn("Couldn't reach Claude. Try again.")
            return
        }
        guard generation == epoch else { return }

        let match = accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        let id = match?.id ?? UUID()
        let existed = match != nil
        guard RosterSessionStore.save(id: id, email: email, refreshToken: tokens.refreshToken) else {
            failSignIn("Couldn't save the sign-in. Try again.")
            return
        }
        guard generation == epoch else {
            if !existed { RosterSessionStore.delete(id: id) }
            return
        }

        var account = match ?? RosterAccount(id: id, email: email)
        account.id = id
        account.email = email
        // The exchange already returned an access token. Reading with it spends no refresh token.
        if let expiresAt = tokens.expiresAt {
            accessTokens[id] = (tokens.accessToken, expiresAt)
        }
        do {
            let meters = try await RosterAPI.usage(accessToken: tokens.accessToken)
            guard generation == epoch else {
                if !existed { forget(id) }
                return
            }
            account.fiveHour = meters.fiveHour
            account.week = meters.week
            account.fetchedAt = Date()
            account.stale = false
            account.error = nil
        } catch RosterAPIError.signedOut {
            account.stale = true
            account.error = "Sign in again."
        } catch {
            account.stale = true
            account.error = "Couldn't read usage."
        }
        guard generation == epoch else {
            if !existed { forget(id) }
            return
        }
        let duplicates = accounts.filter { $0.id != id && $0.email.caseInsensitiveCompare(email) == .orderedSame }
        duplicates.forEach { forget($0.id) }
        accounts.removeAll { duplicates.contains($0) }
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        try? RosterStore.save(RosterSnapshot(accounts: accounts))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.accounts)
        pastedCallback = ""
        signInNote = nil
        isSigningIn = false
        canPaste = false
    }

    /// Drops the stored and cached tokens of an account that is not in the list.
    private func forget(_ id: UUID) {
        RosterSessionStore.delete(id: id)
        accessTokens[id] = nil
    }

    private func failSignIn(_ message: String) {
        signInNote = message
        isSigningIn = false
        canPaste = false
    }
}
