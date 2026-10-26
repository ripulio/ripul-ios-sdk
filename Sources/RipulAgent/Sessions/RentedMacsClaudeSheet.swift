import SwiftUI

// MARK: - Claude for rented Macs

/// One approval that lets every Mac the account's owner rents use Claude Code
/// with nobody at it.
///
/// A rented Mac has nobody to sign Claude Code in. So the owner approves once,
/// here: the paired Mac makes a token for the owner's Claude subscription that
/// lasts a year and can only make model requests, and keeps it in its own
/// keychain (the host's `ClaudeSubscriptionToken`). Each Mac rented from that
/// Mac is given it when it is set up and loses it when it is handed back.
///
/// The steps are the ones `HostSignInSheet` has: the Mac gives an address,
/// this device opens it in Ripul's browser, and the code the page would show
/// is read from its address and goes back as shown (`ClaudeSignInBrowser`).
/// Safari and a pasted code stay as the fallback. The token itself never reaches this device: only
/// whether one is kept, and until about when.
public struct RentedMacsClaudeSheet: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    @Environment(\.dismiss) private var dismiss

    public init(machine: RemoteMachine, bridge: AgentBridge) {
        self.machine = machine
        self.bridge = bridge
    }

    private enum Phase {
        case loading
        case kept(endsAbout: Date?)
        case none(error: String?)
        /// An approval begun earlier, here or elsewhere, still waiting for its code.
        case waitingElsewhere(sessionId: String)
        case awaitingCode(sessionId: String, authUrl: String)
        case submitting
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var code = ""
    @State private var didCopyLink = false
    @State private var confirmForget = false
    @State private var signInPage: ClaudeSignInPage?

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Claude for Rented Macs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .uiKitIdentifier("RentedMacsClaudeSheet.done")
                }
            }
        }
        .ripulSheet(.page, detents: [.medium, .large])
        .ripulSheet(item: $signInPage) { page in
            ClaudeSignInBrowserSheet(authUrl: page.url, machineName: machine.displayName,
                                     onOpenElsewhere: { signInPage = nil; openInSystemBrowser(page.url.absoluteString) },
                                     onFinish: { finishInBrowser($0) })
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Asking \(machine.displayName)…")
                    .foregroundStyle(.ripul(.textSecondary))
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.loading")

        case .kept(let endsAbout):
            VStack(alignment: .leading, spacing: 12) {
                Label("Approved", systemImage: "checkmark.circle.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.success))
                Text("Macs rented from \(machine.displayName) sign in to Claude Code by themselves. The approval is kept on \(machine.displayName) and on each rented Mac while it is rented, and nowhere else.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                if let endsAbout {
                    Text("Good until about \(endsAbout.formatted(date: .long, time: .omitted)).").ripulText()
                        .font(.ripul(.subheadline))
                        .uiKitIdentifier("RentedMacsClaudeSheet.kept.ends")
                }
                Button("Approve Again") { Task { await begin() } }
                    .font(.ripul(.subheadline))
                    .uiKitIdentifier("RentedMacsClaudeSheet.kept.again")
                Button("Forget", role: .destructive) { confirmForget = true }
                    .font(.ripul(.subheadline))
                    .uiKitIdentifier("RentedMacsClaudeSheet.kept.forget")
                    .confirmationDialog("Forget the approval?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { Task { await forget() } }
                    } message: {
                        Text("It is deleted from \(machine.displayName). Macs already rented keep their copy until they are handed back.")
                    }
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.kept")

        case .none(let error):
            VStack(alignment: .leading, spacing: 12) {
                Label("Not approved yet", systemImage: "person.badge.key")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.textSecondary))
                Text("A Mac you rent has nobody at it to sign Claude Code in. Approve once with your own Claude account, and every Mac rented from \(machine.displayName) signs in by itself, for about a year. The approval can only make model requests, and is kept on your own Macs.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.ripul(.caption))
                        .foregroundStyle(.ripul(.danger))
                        .uiKitIdentifier("RentedMacsClaudeSheet.none.error")
                }
                Button {
                    Task { await begin() }
                } label: {
                    Label("Approve with Claude", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .ripulProminentButtonStyle()
                .controlSize(.large)
                .uiKitIdentifier("RentedMacsClaudeSheet.none.approve")
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.none")

        case .waitingElsewhere(let sessionId):
            VStack(alignment: .leading, spacing: 12) {
                Label("Waiting for a code", systemImage: "hourglass")
                    .font(.ripul(.headline))
                Text("\(machine.displayName) is waiting for the code from an approval that was started earlier. Paste it below, or start over for a new page.")
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                codeEntry(sessionId: sessionId)
                Button("Start Over") { Task { await startOver() } }
                    .font(.ripul(.subheadline))
                    .uiKitIdentifier("RentedMacsClaudeSheet.waiting.startOver")
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.waiting")

        case .awaitingCode(let sessionId, let authUrl):
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step 1").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                    Button {
                        open(authUrl)
                    } label: {
                        Label("Open Claude's approval page", systemImage: "person.badge.key")
                            .frame(maxWidth: .infinity)
                    }
                    .ripulProminentButtonStyle()
                    .controlSize(.large)
                    .uiKitIdentifier("RentedMacsClaudeSheet.awaiting.open")
                    Text("Sign in and tap Authorize. The approval finishes by itself. The page stays good for ten minutes.")
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
                        .uiKitIdentifier("RentedMacsClaudeSheet.awaiting.openElsewhere")
                        Button {
                            copy(authUrl)
                        } label: {
                            Label(didCopyLink ? "Link copied" : "Copy link", systemImage: didCopyLink ? "checkmark" : "doc.on.doc")
                                .font(.ripul(.caption))
                        }
                        .buttonStyle(.borderless)
                        .uiKitIdentifier("RentedMacsClaudeSheet.awaiting.copy")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("From Safari").font(.ripul(.caption, weight: .semibold)).foregroundStyle(.ripul(.textSecondary))
                    Text("An approval finished in Safari shows a code. Copy it and paste it here.")
                        .font(.ripul(.subheadline))
                        .foregroundStyle(.ripul(.textSecondary))
                    codeEntry(sessionId: sessionId)
                }
                Button("Cancel", role: .destructive) {
                    Task {
                        _ = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .cancel)
                        await refresh()
                    }
                }
                .font(.ripul(.subheadline))
                .uiKitIdentifier("RentedMacsClaudeSheet.awaiting.cancel")
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.awaiting")

        case .submitting:
            HStack(spacing: 10) {
                ProgressView()
                Text("\(machine.displayName) is finishing the approval…").ripulText()
                    .font(.ripul(.headline))
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.submitting")

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Not approved", systemImage: "xmark.octagon.fill")
                    .font(.ripul(.headline))
                    .foregroundStyle(.ripul(.danger))
                Text(message)
                    .font(.ripul(.subheadline))
                    .foregroundStyle(.ripul(.textSecondary))
                    .uiKitIdentifier("RentedMacsClaudeSheet.failed.message")
                Text("A code works once, and only for the page that was opened last. Start over to open a new page, approve there, and paste the code it shows.")
                    .font(.ripul(.caption)) // theme-mapping: a new line of help, nothing is replaced
                    .foregroundStyle(.ripul(.textSecondary)) // theme-mapping: a new line of help, nothing is replaced
                    .uiKitIdentifier("RentedMacsClaudeSheet.failed.hint")
                Button("Start Over") { Task { await startOver() } }
                    .ripulProminentButtonStyle()
                    .uiKitIdentifier("RentedMacsClaudeSheet.failed.again")
            }
            .uiKitIdentifier("RentedMacsClaudeSheet.failed")
        }
    }

    /// The field does nothing to what is pasted: the code goes to the Mac as
    /// shown, and the Mac trims it.
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
            .uiKitIdentifier("RentedMacsClaudeSheet.codeField")
        Button {
            Task { await submit(sessionId: sessionId, code: code) }
        } label: {
            Text("Finish").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .uiKitIdentifier("RentedMacsClaudeSheet.finish")
    }

    // MARK: - Actions

    private func refresh() async {
        phase = .loading
        let status = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .status)
        if status.stored { phase = .kept(endsAbout: status.endsAbout) }
        else if let pending = status.pendingSessionId { phase = .waitingElsewhere(sessionId: pending) }
        else { phase = .none(error: status.error) }
    }

    private func begin() async {
        phase = .loading
        code = ""
        didCopyLink = false
        let begun = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .begin)
        if let sessionId = begun.sessionId, let authUrl = begun.authUrl {
            phase = .awaitingCode(sessionId: sessionId, authUrl: authUrl)
            open(authUrl)
        } else {
            phase = .none(error: begun.error ?? "The approval could not be started.")
        }
    }

    private func startOver() async {
        phase = .loading
        _ = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .cancel)
        await begin()
    }

    private func submit(sessionId: String, code: String) async {
        phase = .submitting
        let done = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .code(sessionId: sessionId, code: code))
        if done.ok { await refresh() }
        else { phase = .failed(done.error ?? "\(machine.displayName) could not finish the approval.") }
    }

    private func forget() async {
        phase = .loading
        _ = await bridge.rentedMacsClaudeToken(machineId: machine.machineId, step: .forget)
        await refresh()
    }

    /// Ripul's browser, over this sheet. Its callback lands in `finishInBrowser`.
    private func open(_ authUrl: String) {
        guard let url = URL(string: authUrl) else { return }
        signInPage = ClaudeSignInPage(url: url)
    }

    /// The code read from the page's address goes the way a pasted one does,
    /// and is never put in the field.
    private func finishInBrowser(_ outcome: ClaudeSignInBrowser.Outcome?) {
        signInPage = nil
        guard case .awaitingCode(let sessionId, _) = phase, let outcome else { return }
        switch outcome {
        case .code(let found): Task { await submit(sessionId: sessionId, code: found) }
        case .refused(let message), .denied(let message): phase = .failed(message)
        }
    }

    private func openInSystemBrowser(_ authUrl: String) {
        guard let url = URL(string: authUrl) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copy(_ authUrl: String) {
        #if os(iOS)
        UIPasteboard.general.string = authUrl
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authUrl, forType: .string)
        #endif
        didCopyLink = true
    }
}
