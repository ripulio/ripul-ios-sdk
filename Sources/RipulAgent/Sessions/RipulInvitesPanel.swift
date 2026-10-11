#if os(iOS)
import SwiftUI

/// The session list's Invites panel — the list's default when a host injects
/// no `invitesSection`. It moved here from the Ripul app so every host gets
/// it: an invite is the only way in for a guest with no Mac and no chats, and
/// a host without the panel (WAC's developer console) left that guest with
/// nothing to tap.
///
/// Join is a real, awaited action: it joins through the web app, waits for the
/// resulting chat tab, opens it, and keeps the invite as a standing way back.
@available(iOS 26.0, *)
struct RipulInvitesPanel: View {
    var bridge: AgentBridge
    var actions: InvitesSectionActions? = nil

    @ObservedObject var inviteManager: RipulInviteManager
    @State private var invitesExpanded = true
    @State private var isSelectingInvites = false
    @State private var selectedInviteTokens: Set<String> = []
    @State private var showBatchDismissInvitesConfirm = false
    /// Token of the invite currently being joined — drives its row spinner.
    @State private var joiningToken: String? = nil
    /// Why the last join failed, shown inline under the panel. A silent
    /// failure is what made this whole flow untrustworthy.
    @State private var joinError: String? = nil
    @State private var leavingInvite: RipulShareInvite?

    var body: some View {
        // The twin rendered the panel only when invites exist — keep that.
        if !inviteManager.invites.isEmpty {
            content
                .confirmationDialog("Leave this chat?", isPresented: Binding(get: { leavingInvite != nil }, set: { if !$0 { leavingInvite = nil } })) {
                    Button("Leave chat", role: .destructive) {
                        guard let invite = leavingInvite else { return }
                        Task {
                            do { try await inviteManager.leaveChat(invite) }
                            catch { joinError = error.localizedDescription }
                            leavingInvite = nil
                        }
                    }
                } message: {
                    Text("You will need a new invitation to join again.")
                }
        } else {
            // Still fetch on appear so a later invite appearing flips us visible.
            Color.clear.frame(height: 0)
                .task { await inviteManager.fetchInvites() }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            GlassSectionPanel(
                title: "Invites (\(inviteManager.invites.count))",
                isExpanded: $invitesExpanded,
                trailing: {
                    GlassSelectButton(isSelecting: isSelectingInvites) {
                        if isSelectingInvites {
                            isSelectingInvites = false
                            selectedInviteTokens.removeAll()
                        } else {
                            isSelectingInvites = true
                        }
                    }
                    .uiKitIdentifier("GlassSessionsList.invites.selectButton")
                }
            ) {
                List {
                    ForEach(inviteManager.invites) { invite in
                        HStack(spacing: 12) {
                            if isSelectingInvites {
                                Image(systemName: selectedInviteTokens.contains(invite.token) ? "checkmark.circle.fill" : "circle")
                                    .font(.ripulIcon(.title3))
                                    .foregroundStyle(selectedInviteTokens.contains(invite.token) ? Color.accentColor : Color.ripul(.textSecondary))
                                    .animation(.easeInOut(duration: 0.15), value: selectedInviteTokens.contains(invite.token))
                                    .uiKitIdentifier("GlassSessionsList.invites.selectionCheckmark")
                            }

                            Image(systemName: "envelope.badge")
                                .font(.ripulIcon(size: 16))
                                .foregroundStyle(.ripul(.info))
                                .frame(width: 28)
                                .uiKitIdentifier("GlassSessionsList.invites.envelopeIcon")

                            VStack(alignment: .leading, spacing: 2) {
                                Text(invite.displayLabel)
                                    .font(.ripul(.body))
                                    .foregroundStyle(.ripul(.text))
                                    .lineLimit(1)
                                    .uiKitIdentifier("GlassSessionsList.invites.displayLabel")
                                Text(invite.accepted == true ? "Joined chat" : "From \(invite.inviterName ?? "someone")")
                                    .font(.ripul(.caption))
                                    .foregroundStyle(.ripul(.textSecondary))
                                    .uiKitIdentifier("GlassSessionsList.invites.inviterName")
                            }

                            Spacer()

                            if !isSelectingInvites {
                                if joiningToken == invite.token {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Joining…")
                                            .font(.ripul(.caption, weight: .semibold))
                                            .foregroundStyle(.ripul(.textSecondary))
                                    }
                                    .uiKitIdentifier("GlassSessionsList.invites.joiningLabel")
                                } else {
                                    Text(invite.accepted == true ? "Open" : "Join")
                                        .font(.ripul(.caption, weight: .semibold))
                                        .foregroundStyle(joiningToken == nil ? Color.ripul(.info) : Color.ripul(.textSecondary))
                                        .uiKitIdentifier("GlassSessionsList.invites.joinLabel")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelectingInvites {
                                if selectedInviteTokens.contains(invite.token) {
                                    selectedInviteTokens.remove(invite.token)
                                } else {
                                    selectedInviteTokens.insert(invite.token)
                                }
                            } else if joiningToken == nil {
                                Task { await join(invite) }
                            }
                        }
                        .contextMenu { MenuIcons {
                            if invite.accepted == true {
                                Button("Leave chat", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    leavingInvite = invite
                                }
                            }
                        }}
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelectingInvites {
                                Button(role: .destructive) {
                                    Task { await inviteManager.dismissInvite(invite) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .uiKitIdentifier("GlassSessionsList.invites.swipeRemoveButton")
                            }
                        }
                        .listRowBackground(
                            isSelectingInvites && selectedInviteTokens.contains(invite.token)
                                ? Color.accentColor.opacity(0.08)
                                : Color.clear
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // A row's height each, up to five rows, then it scrolls. This was
                // `minHeight: rows * 48, maxHeight: 240`: past five invites the
                // minimum beat the maximum, the panel grew a row per invite and
                // the list no longer fitted the screen.
                .frame(height: min(CGFloat(inviteManager.invites.count) * 48, 240))
            }

            if let joinError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .uiKitIdentifier("GlassSessionsList.invites.joinErrorIcon")
                    Text(joinError)
                        .font(.ripul(.caption))
                        .uiKitIdentifier("GlassSessionsList.invites.joinErrorText")
                }
                .foregroundStyle(.ripul(.warning))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            // Batch remove (was the twin's floating action bar button)
            if isSelectingInvites && !selectedInviteTokens.isEmpty {
                Button {
                    showBatchDismissInvitesConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .uiKitIdentifier("GlassSessionsList.batch.removeInvitesIcon")
                        Text("Remove (\(selectedInviteTokens.count))")
                            .fontWeight(.medium)
                            .uiKitIdentifier("GlassSessionsList.batch.removeInvitesLabel")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.capsule)
                }
                .uiKitIdentifier("SessionListScreen.batch.removeInvitesButton")
                .buttonStyle(.plain)
                .foregroundStyle(.ripul(.danger))
                .glassEffect(.clear.interactive(), in: .capsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isSelectingInvites)
        .animation(.easeInOut(duration: 0.25), value: selectedInviteTokens.count)
        .animation(.easeInOut(duration: 0.2), value: joiningToken)
        .animation(.easeInOut(duration: 0.2), value: joinError)
        .confirmationDialog(
            "Remove \(selectedInviteTokens.count) invite\(selectedInviteTokens.count == 1 ? "" : "s")?",
            isPresented: $showBatchDismissInvitesConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove \(selectedInviteTokens.count) Invite\(selectedInviteTokens.count == 1 ? "" : "s")", role: .destructive) {
                let tokens = selectedInviteTokens
                isSelectingInvites = false
                selectedInviteTokens.removeAll()
                Task {
                    for invite in inviteManager.invites where tokens.contains(invite.token) {
                        await inviteManager.dismissInvite(invite)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Join

    @MainActor
    private func join(_ invite: RipulShareInvite) async {
        joiningToken = invite.token
        joinError = nil
        defer { joiningToken = nil }

        let result = await bridge.joinShareLink(token: invite.token)
        guard let tabId = result.tabId else {
            joinError = result.error.map(Self.readable) ?? "Couldn't join that session."
            return
        }

        // The web app has the tab; `bridge.sessions` is a polled snapshot, so
        // it may not have caught up yet even though joinShareLink kicked a
        // fetch. Wait for the row rather than opening nothing.
        guard let session = await awaitSession(tabId: tabId) else {
            joinError = "Joined, but the chat hasn't appeared yet — pull to refresh."
            return
        }

        // Open first. The invite refresh below is a full network round trip
        // that used to sit between the tap and the navigation, so on a slow
        // link the user watched "Joining…" long after the join had succeeded.
        actions?.openChat(session)

        // The invite STAYS. It's a standing way back into the shared session,
        // not a one-shot ticket — joinShareLink is idempotent (an existing
        // pairing is re-focused, not duplicated), so tapping Join again just
        // reopens the chat. Only the user removes an invite, by swiping the
        // row or using the batch Remove. Refreshing flips the row from
        // "Join" to "Open"; nothing waits on it.
        Task { await inviteManager.fetchInvites() }
    }

    /// A join that failed because the page did not answer comes back as one of
    /// the bridge's codes, or in WebKit's own words. Say it the way the rest of
    /// the app does. Anything else is the server's or the web app's sentence.
    static func readable(_ error: String) -> String {
        let pageCodes = ["web-context-dead:", "web-crashed:", "callables-absent:", "not-ready:", "no-web-view:"]
        guard pageCodes.contains(where: { error.hasPrefix($0) }) || error.contains("unsupported type") else { return error }
        return ConnectionDiagnosis.classify(rawError: error, phase: nil).summary + ". Try again in a few seconds."
    }

    /// Poll `bridge.sessions` for the joined tab. ~10s is generous next to the
    /// 3s session poll and leaves room for a slow relay handshake.
    @MainActor
    private func awaitSession(tabId: String) async -> ChatSession? {
        for tick in 0..<50 {
            if let match = bridge.sessions.first(where: { $0.id == tabId || $0.sourceChatId == tabId }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Nudge the bridge every second — the background poll is throttled.
            if tick % 5 == 4 { await bridge.fetchSessions() }
        }
        return nil
    }
}
#endif
