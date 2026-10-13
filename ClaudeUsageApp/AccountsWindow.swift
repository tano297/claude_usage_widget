import AppKit
import SwiftUI

/// Set before Open. A login-item launch can restore this window; that copy closes itself.
enum AccountsWindowLaunch {
    static var requested = false
}

/// Add and remove roster subscriptions. The Claude CLI account is not managed here.
struct AccountsWindow: View {
    @ObservedObject var roster: RosterController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RosterBrowser.profileKey) private var chromeProfile = ""
    @State private var chromeProfiles: [ChromeProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each sign-in opens a private Chrome window, or the Chrome profile you pick. Log into one account, then add the next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if RosterBrowser.hasChrome {
                // A profile keeps its saved logins. A private window starts signed out.
                Picker("Sign in with", selection: $chromeProfile) {
                    Text("Private window").tag("")
                    ForEach(chromeProfiles) { profile in
                        Text(profile.name).tag(profile.directory)
                    }
                }
                .fixedSize()
                .disabled(roster.isSigningIn)
            }

            if roster.accounts.isEmpty && !roster.isSigningIn {
                Text("No extra subscriptions yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            ForEach(roster.accounts) { account in
                HStack(spacing: 8) {
                    Button {
                        roster.remove(account)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(roster.isSigningIn)
                    .help("Remove \(account.email)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let error = account.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                }
            }

            Button {
                roster.beginSignIn()
            } label: {
                Label("Add account", systemImage: "plus")
            }
            .disabled(roster.isSigningIn)

            if roster.isSigningIn {
                Text(roster.signInNote ?? "Waiting for the browser…")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Paste the localhost address if the window stays there", text: $roster.pastedCallback)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!roster.canPaste)
                HStack {
                    Button("Use this address") { roster.submitPasted() }
                        .disabled(!roster.canPaste || roster.pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { roster.cancelSignIn() }
                }
            } else if let note = roster.signInNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420, alignment: .topLeading)
        .onAppear {
            chromeProfiles = RosterBrowser.chromeProfiles()
            // A profile Chrome no longer has falls back to a private window.
            if !chromeProfile.isEmpty, !chromeProfiles.contains(where: { $0.directory == chromeProfile }) {
                chromeProfile = ""
            }
            // A restored window reaches onAppear with requested still false. Wait one turn so an
            // Open click in the same moment is not closed by that dismissal.
            DispatchQueue.main.async {
                guard AccountsWindowLaunch.requested else {
                    dismiss()
                    NSApp.setActivationPolicy(.accessory)
                    return
                }
                for window in NSApp.windows where window.title == "Subscriptions" {
                    window.isRestorable = false
                }
            }
        }
        .onDisappear(perform: leaveAccessory)
    }

    private func close() {
        leaveAccessory()
        dismiss()
    }

    /// The menu-bar app has no Dock icon. The icon exists only while this window can take focus.
    private func leaveAccessory() {
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains { $0.title == "Subscriptions" && $0.isVisible }
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
