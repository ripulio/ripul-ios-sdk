import SwiftUI
import AuthenticationServices

// MARK: - Host Claude Sign-In Sheet

/// Phone-driven Claude sign-in for a paired host machine.
///
/// The host's `claude auth login` emits an authorize URL whose callback is a HOSTED page (not
/// localhost), so the browser half of the OAuth flow can run on this device while the
/// credential lands in the host's Keychain. The flow:
///
/// 1. `beginHostAuth` — host spawns the login, we get the authorize URL
/// 2. User signs in in Ripul's own browser (`ClaudeSignInBrowser`), which
///    catches the callback page's address and reads the code from it
/// 3. `submitHostAuthCode` — code goes back VERBATIM; host redeems it
///
/// A Mac from 4 November 2026 also gives `returnUrl`: the same sign-in returning
/// to Claude Code's own listener on `http://localhost:<port>/callback`. Then
/// this device listens on that port itself (`LoopbackSignInReturn`) and opens
/// the address in the system's sign-in sheet, which is Safari: Google's sign-in
/// refuses a web view inside an app, so Claude accounts signed in with Google
/// could not finish in Ripul's own browser. The browser's return lands here,
/// closes the sheet, and goes to the Mac as the code. Nothing to copy.
///
/// The code is `<code>#<state>` and must not be split on `#` — the
/// CLI silently rejects the left half alone. It is also single-use: submission
/// is never retried, and a failed attempt requires starting over.
///
/// Ripul's browser has the cookies of the Browser screen and passed claude.ai's
/// checks on 23 October 2026 (SFSafariViewController did not: it shares no
/// cookies and rendered the page blank on Catalyst). Safari and the paste field
/// stay as the fallback.
///
/// Those cookies also decide the account: Claude's page signs in whichever
/// account the Browser is signed in to, without asking, and offers no way to
/// leave it. On 3 November 2026 two tries at adding a MacBook to one account
/// both signed it in to another. So the page has a Sign Out (the browser
/// forgets Claude's sign-in and Claude asks who), and a sign-in meant for a
/// known account (`expectedEmail`) is checked when it finishes: a different
/// account is said plainly, with a way to sign out and sign in again.
public struct HostSignInSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    /// Account profile this sign-in writes to (account switcher). nil = the
    /// host's ACTIVE profile — the pre-switcher behavior.
    let profile: String?
    let profileName: String?
    let startSignInImmediately: Bool
    /// The account this sign-in is for, when that is known: the account a
    /// computer is being added to, or the one the profile was signed in to.
    let expectedEmail: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    public init(machine: RemoteMachine, bridge: AgentBridge, profile: String? = nil, profileName: String? = nil,
                startSignInImmediately: Bool = false, expectedEmail: String? = nil) {
        self.machine = machine
        self.bridge = bridge
        self.profile = profile
        self.profileName = profileName
        self.startSignInImmediately = startSignInImmediately
        self.expectedEmail = expectedEmail
    }

    private enum Phase {
        case loading
        /// Signed in — showing account details.
        case signedIn(HostAuthStatusInfo)
        /// Not signed in, no flow in flight.
        case idle(error: String?)
        /// A sign-in was started earlier (possibly from another device) and the
        /// host is still holding it open for a code. No authUrl survives a
        /// status probe, so offer "enter code" or "start over".
        case pendingElsewhere(sessionId: String)
        /// We started a sign-in and have the URL to open, and the one that
        /// returns to this device when the Mac gave it.
        case awaitingCode(sessionId: String, authUrl: String, returnUrl: String?)
        case submitting
        case success(HostAuthStatusInfo?)
        /// Signed in, but to another account than `expectedEmail`.
        case wrongAccount(HostAuthStatusInfo)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var code: String = ""
    @State private var didCopyLink = false
    @State private var signInPage: ClaudeSignInPage?
    /// Set by "Sign in with a different account": another account is the point.
    @State private var acceptsAnyAccount = false
    /// The system's sheet opens without Safari's sign-ins, so Claude asks which
    /// account: set when another account is wanted.
    @State private var freshBrowser = false

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Claude Code's own folder ("default") is not an account with a name of its own.
            .navigationTitle(profile.flatMap { $0 == CodingAccountDefaultFolder.slug ? nil : $0 }
                .map { "\(profileName ?? $0) on \(machine.displayName)" } ?? "Claude on \(machine.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("HostSignInSheet.done")
                }
            }
        }
        .ripulSheet(.page, detents: [.medium, .large])
        .ripulSheet(item: $signInPage) { page in
            ClaudeSignInBrowserSheet(authUrl: page.url, machineName: machine.displayName,
                                     onOpenElsewhere: { signInPage = nil; openInSystemBrowser(page.url.absoluteString) },
                                     onFinish: { finishInBrowser($0) })
        }
        .task {
            if startSignInImmediately { await begin() }
            else { await refreshStatus() }
        }
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking sign-in status…")
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("HostSignInSheet.loading")

        case .signedIn(let status):
            signedInView(status)

        case .idle(let error):
            idleView(error: error)

        case .pendingElsewhere(let sessionId):
            pendingElsewhereView(sessionId: sessionId)

        case .awaitingCode(let sessionId, let authUrl, let returnUrl):
            awaitingCodeView(sessionId: sessionId, authUrl: authUrl, returnUrl: returnUrl)

        case .submitting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verifying…").ripulText()
                        .font(.ripul(.headline))
                }
                Text("The Mac is redeeming the code and confirming the sign-in. This can take up to 90 seconds.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("HostSignInSheet.submitting")

        case .success(let status):
            VStack(alignment: .leading, spacing: 12) {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.success))
                if let status {
                    accountRows(status)
                }
                Text("Claude Code sessions on \(machine.displayName) are now billed to this sign-in.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("HostSignInSheet.success")

        case .wrongAccount(let status):
            wrongAccountView(status)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Sign-in failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.warning))
                Text(message)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("The code is single-use, so a failed attempt can't be retried — start over to get a fresh sign-in page.")
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.textSecondary))
                Button("Start Over") {
                    Task { await startOver() }
                }
                .ripulProminentButtonStyle()
                .uiKitIdentifier("HostSignInSheet.failed.startOver")
            }
            .uiKitIdentifier("HostSignInSheet.failed")
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedInView(_ status: HostAuthStatusInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .font(.ripul(.headline))
                .foregroundStyle(.ripul(.success))
            accountRows(status)
            Divider()
            Button("Sign in with a different account") {
                acceptsAnyAccount = true
                freshBrowser = true
                Task { await begin() }
            }
            .font(.ripul(.subheadline))
            .uiKitIdentifier("HostSignInSheet.signedIn.switchAccount")
        }
        .uiKitIdentifier("HostSignInSheet.signedIn")
    }

    // MARK: - Signed in to another account

    @ViewBuilder
    private func wrongAccountView(_ status: HostAuthStatusInfo) -> some View {
        let expected = expectedEmail ?? ""
        let actual = status.email ?? "another account"
        VStack(alignment: .leading, spacing: 12) {
            Label("Signed in to a different account", systemImage: "exclamationmark.triangle.fill")
                .font(.ripul(.headline)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .foregroundStyle(.ripul(.warning)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
            Text("\(profileName ?? "Claude") on \(machine.displayName) is now signed in as \(actual), not \(expected).")
                .font(.ripul(.subheadline)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .foregroundStyle(.ripul(.text)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .fixedSize(horizontal: false, vertical: true)
            Text("Claude's page used the account the browser was signed in to. Signing in again opens it signed out of Claude, so Claude asks which account to use.")
                .font(.ripul(.caption)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .foregroundStyle(.ripul(.textSecondary)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    freshBrowser = true
                    await ClaudeSignInBrowser.signOutOfClaude()
                    await begin()
                }
            } label: {
                Label("Sign In as \(expected)", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .ripulProminentButtonStyle()
            .controlSize(.large)
            .uiKitIdentifier("HostSignInSheet.wrongAccount.signInAgain")
            Button("Keep \(actual)") { dismiss() }
                .font(.ripul(.subheadline)) // theme-mapping: a new line of the sign-in sheet, nothing is replaced
                .uiKitIdentifier("HostSignInSheet.wrongAccount.keep")
        }
        .uiKitIdentifier("HostSignInSheet.wrongAccount")
    }

    @ViewBuilder
    private func accountRows(_ status: HostAuthStatusInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let email = status.email {
                detailRow("envelope", email)
            }
            if let org = status.orgName {
                detailRow("building.2", org)
            }
            if let plan = status.subscriptionType {
                detailRow("creditcard", plan.capitalized)
            }
        }
    }

    private func detailRow(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.ripulIcon(.caption))
                .foregroundStyle(.ripul(.textSecondary))
                .frame(width: 18)
            Text(value).ripulText()
                .font(.ripul(.subheadline))
        }
    }

    // MARK: - Idle (not signed in)

    @ViewBuilder
    private func idleView(error: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                .font(.ripul(.headline))
                .foregroundStyle(.ripul(.textSecondary))
            Text("Claude Code on \(machine.displayName) has no Claude account. Sign in from this device — the account stays on the Mac.")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
            if let error, !error.isEmpty {
                Text(error)
                    .font(.ripul(.caption))
                    .foregroundStyle(.ripul(.warning))
            }
            Button {
                Task { await begin() }
            } label: {
                Label("Sign in with Claude", systemImage: "person.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .ripulProminentButtonStyle()
            .controlSize(.large)
            .uiKitIdentifier("HostSignInSheet.idle.signIn")
        }
        .uiKitIdentifier("HostSignInSheet.idle")
    }

    // MARK: - Pending from elsewhere

    @ViewBuilder
    private func pendingElsewhereView(sessionId: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign-in already in progress", systemImage: "hourglass")
                .font(.ripul(.headline))
            Text("The Mac is waiting for a sign-in code. If you already have the code, paste it below; otherwise start over for a fresh sign-in page.")
                .font(.ripul(.subheadline))
                .foregroundStyle(.ripul(.textSecondary))
            codeEntry(sessionId: sessionId)
            Button("Start Over") {
                Task { await startOver() }
            }
            .font(.ripul(.subheadline))
            .uiKitIdentifier("HostSignInSheet.pending.startOver")
        }
        .uiKitIdentifier("HostSignInSheet.pending")
    }

    // MARK: - Awaiting code

    @ViewBuilder
    private func awaitingCodeView(sessionId: String, authUrl: String, returnUrl: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Step 1").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                Button {
                    openSignIn(sessionId: sessionId, authUrl: authUrl, returnUrl: returnUrl)
                } label: {
                    Label("Open the sign-in page", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .ripulProminentButtonStyle()
                .controlSize(.large)
                .uiKitIdentifier("HostSignInSheet.awaiting.openUrl")
                Text(returnUrl == nil ? "Sign in and tap Authorize. The sign-in finishes by itself. Sign Out on the page changes the account."
                     : "Sign in and tap Authorize. The page closes by itself and the sign-in finishes here.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))

                HStack(spacing: 16) {
                    Button {
                        openInSystemBrowser(authUrl)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                            .font(.ripul(.caption))
                    }
                    .buttonStyle(.borderless)
                    .uiKitIdentifier("HostSignInSheet.awaiting.openElsewhere")
                    Button {
                        copyLink(authUrl)
                    } label: {
                        Label(didCopyLink ? "Link copied" : "Copy link", systemImage: didCopyLink ? "checkmark" : "doc.on.doc")
                            .font(.ripul(.caption))
                    }
                    .buttonStyle(.borderless)
                    .uiKitIdentifier("HostSignInSheet.awaiting.copyUrl")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("From Safari").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                Text("A sign-in finished in Safari shows a code. Copy it and paste it here.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                codeEntry(sessionId: sessionId)
            }

            Button("Cancel sign-in", role: .destructive) {
                Task {
                    _ = await bridge.cancelHostAuth(machineId: machine.machineId)
                    await refreshStatus()
                }
            }
            .font(.ripul(.subheadline))
            .uiKitIdentifier("HostSignInSheet.awaiting.cancel")
        }
        .uiKitIdentifier("HostSignInSheet.awaiting")
    }

    /// Shared code field + submit. The field deliberately does nothing to the
    /// pasted text: the code is `<code>#<state>` and must reach the host
    /// verbatim (the host strips whitespace itself).
    @ViewBuilder
    private func codeEntry(sessionId: String) -> some View {
        TextField("Paste code here", text: $code)
            .font(.ripul(.body, family: .code))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif
            .textFieldStyle(.roundedBorder)
            .uiKitIdentifier("HostSignInSheet.codeField")

        Button {
            Task { await submit(sessionId: sessionId, code: code) }
        } label: {
            Text("Submit Code")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .uiKitIdentifier("HostSignInSheet.submitCode")
    }

    // MARK: - Actions

    private func refreshStatus() async {
        phase = .loading
        let status = await bridge.fetchHostAuthStatus(machineId: machine.machineId, profile: profile)
        if status.loggedIn {
            phase = .signedIn(status)
        } else if let pending = status.pendingSessionId {
            phase = .pendingElsewhere(sessionId: pending)
        } else {
            phase = .idle(error: status.error)
        }
    }

    private func begin() async {
        phase = .loading
        code = ""
        didCopyLink = false
        let result = await bridge.beginHostAuth(machineId: machine.machineId, profile: profile)
        if let sessionId = result.sessionId, let authUrl = result.authUrl {
            phase = .awaitingCode(sessionId: sessionId, authUrl: authUrl, returnUrl: result.returnUrl)
            openSignIn(sessionId: sessionId, authUrl: authUrl, returnUrl: result.returnUrl)
        } else {
            phase = .idle(error: result.error ?? "Could not start the sign-in")
        }
    }

    private func startOver() async {
        phase = .loading
        _ = await bridge.cancelHostAuth(machineId: machine.machineId)
        await begin()
    }

    private func submit(sessionId: String, code: String) async {
        phase = .submitting
        let (ok, error) = await bridge.submitHostAuthCode(
            machineId: machine.machineId,
            sessionId: sessionId,
            code: code,
            profile: profile
        )
        if ok {
            let status = await bridge.fetchHostAuthStatus(machineId: machine.machineId, profile: profile)
            if status.loggedIn, !acceptsAnyAccount,
               CodingAccountEmail.isDifferentAccount(expected: expectedEmail, signedIn: status.email) {
                phase = .wrongAccount(status)
            } else {
                phase = .success(status.loggedIn ? status : nil)
            }
        } else {
            phase = .failed(error ?? "The host could not verify the code.")
        }
    }

    /// The system's sheet when the sign-in can return to this device, and
    /// otherwise Ripul's browser.
    private func openSignIn(sessionId: String, authUrl: String, returnUrl: String?) {
        guard let returnUrl, let address = URL(string: returnUrl),
              let catcher = LoopbackSignInReturn(authorizeURL: address) else {
            openAuthUrl(authUrl)
            return
        }
        Task { await signInReturning(sessionId: sessionId, address: address, catcher: catcher) }
    }

    /// Listens for the browser's return on this device, opens the sign-in in the
    /// system's sheet, and sends what came back to the Mac. The sheet closes
    /// itself when the return arrives. Closed before that, the sheet leaves the
    /// sign-in waiting, with Safari and the paste field still offered.
    private func signInReturning(sessionId: String, address: URL, catcher: LoopbackSignInReturn) async {
        _ = await catcher.start()
        defer { catcher.stop() }
        _ = try? await webAuthenticationSession.authenticate(
            using: address, callbackURLScheme: LoopbackSignInReturn.scheme,
            preferredBrowserSession: freshBrowser ? .ephemeral : .shared)
        guard case .awaitingCode(let waiting, _, _) = phase, waiting == sessionId else { return }
        switch catcher.outcome {
        case .returned(let returned): await submit(sessionId: sessionId, code: returned)
        case .denied(let message): phase = .failed(message)
        case nil:
            // On the Mac being signed in (Catalyst, or a simulator sharing its
            // loopback) the browser can return to Claude Code's own listener,
            // which finishes by itself. Otherwise the sheet was closed early,
            // and the sign-in waits as it was.
            let status = await bridge.fetchHostAuthStatus(machineId: machine.machineId, profile: profile)
            guard case .awaitingCode(let still, _, _) = phase, still == sessionId else { return }
            if status.loggedIn && status.pendingSessionId == nil { phase = .success(status) }
        }
    }

    /// Ripul's browser, over this sheet. Its callback lands in `finishInBrowser`.
    private func openAuthUrl(_ authUrl: String) {
        guard let url = URL(string: authUrl) else { return }
        signInPage = ClaudeSignInPage(url: url)
    }

    /// The page's callback, read from its address: the code goes the same way a
    /// pasted one does, and is never put in the field.
    private func finishInBrowser(_ outcome: ClaudeSignInBrowser.Outcome?) {
        signInPage = nil
        guard case .awaitingCode(let sessionId, _, _) = phase, let outcome else { return }
        switch outcome {
        case .code(let found): Task { await submit(sessionId: sessionId, code: found) }
        case .refused(let message), .denied(let message): phase = .failed(message)
        }
    }

    private func openInSystemBrowser(_ authUrl: String) {
        guard let url = URL(string: authUrl) else { return }
        #if os(iOS)
        // UIApplication.open is the system handoff on iOS, and on Catalyst it
        // reaches the Mac's default browser.
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copyLink(_ authUrl: String) {
        #if os(iOS)
        UIPasteboard.general.string = authUrl
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authUrl, forType: .string)
        #endif
        didCopyLink = true
    }
}
