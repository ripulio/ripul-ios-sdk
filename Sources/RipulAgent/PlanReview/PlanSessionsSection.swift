import SwiftUI

/// "Sessions on this plan" — the plan detail screen's session mini-list, as
/// the same `GlassSectionPanel` the agents screen wraps its panels in.
///
/// Observes the host's long-lived `RipulSessionListModel` (the app's session
/// manager): the list is an in-memory filter over sessions the app is already
/// tracking, so live turn phase, the tool lozenge and last-active all come
/// from `UnifiedSessionRow` for free.
///
/// Sessions join three ways: launched from the plan's run sheet (tagged at
/// creation), by writing to the plan's log (tagged at first write), or linked
/// by hand — the header's link button raises `showLinkPicker`, and the HOST
/// presents `PlanSessionLinkPicker` from its stable sheet level. Presenting
/// from inside the host's List section knocked the sheet down mid-present.
/// Long-press a row to unlink.
@available(iOS 26.0, macOS 26.0, *)
public struct PlanSessionsSection: View {
    /// One-shot latch so re-renders do not re-kick the refresh.
    private final class RefreshKick: ObservableObject { var started = false }

    private let bridge: AgentBridge
    @ObservedObject private var model: RipulSessionListModel
    @ObservedObject private var sessionStore: SessionListStore
    @StateObject private var kick = RefreshKick()
    @State private var expanded = true
    private let planKey: String
    private let showLinkPicker: Binding<Bool>
    private let onOpenChat: (ChatSession) -> Void

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        planKey: String,
        showLinkPicker: Binding<Bool>,
        onOpenChat: @escaping (ChatSession) -> Void
    ) {
        self.bridge = bridge
        self.model = model
        self.sessionStore = bridge.sessionList
        self.planKey = planKey
        self.showLinkPicker = showLinkPicker
        self.onOpenChat = onOpenChat
    }

    /// Sessions carrying this plan's link tag, most recent first, capped so a
    /// much-worked plan does not bury its own document.
    private var matching: [UnifiedSession] {
        Array(
            model.unifiedSessions
                .filter { $0.tags.contains(planKey) }
                .sorted { $0.lastUsed > $1.lastUsed }
                .prefix(5)
        )
    }

    public var body: some View {
        GlassSectionPanel(
            title: "Sessions on this plan",
            subtitle: matching.isEmpty ? "None" : "\(matching.count)",
            isExpanded: $expanded,
            trailing: {
                Button {
                    showLinkPicker.wrappedValue = true
                } label: {
                    Image(systemName: "link.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .uiKitIdentifier("PlanSessionsSection.linkButton")
            }
        ) {
            VStack(spacing: 0) {
                ForEach(matching) { session in
                    HStack(spacing: 4) {
                        UnifiedSessionRow(
                            sessionStore: sessionStore,
                            session: session,
                            isOpening: model.openingUnifiedSessionId == session.id,
                            hideProjectName: true
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.openSession(session, onSelect: onOpenChat, onDismiss: {})
                        }

                        // A VISIBLE unlink affordance — the long-press menu
                        // below stays, but a machine tag the user cannot see
                        // removed deserves a control they can see.
                        Menu {
                            Button(role: .destructive) {
                                setLink(session, linked: false)
                            } label: {
                                Label("Unlink from plan", systemImage: "minus.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 44)
                                .contentShape(Rectangle())
                        }
                        .uiKitIdentifier("PlanSessionsSection.rowMenu")
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            setLink(session, linked: false)
                        } label: {
                            Label("Unlink from plan", systemImage: "minus.circle")
                        }
                    }
                    .padding(.horizontal, 8)
                    .uiKitIdentifier("PlanSessionsSection.row")
                }
                if matching.isEmpty {
                    Text("No sessions yet — runs started from this plan appear here, or link one with the + button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
        .task { await refreshOnce() }
        .onReceive(NotificationCenter.default.publisher(for: .ripulPlanRunStarted)) { note in
            guard (note.userInfo?["planKey"] as? String) == planKey else { return }
            // Twice: once now, once after the new session and its tag have
            // had a beat to land server-side — a started run must show up.
            Task {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await model.refresh()
            }
        }
    }

    private func setLink(_ session: UnifiedSession, linked: Bool) {
        Task {
            _ = await bridge.planLinkSession(
                sessionId: session.metadataKey,
                planKey: planKey,
                linked: linked
            )
            await model.refresh()
        }
    }

    /// Freshen tags and remote sessions once per appearance of the screen —
    /// the tag written when a run starts is server-side, so a list refreshed
    /// before it landed would hide a session that exists.
    private func refreshOnce() async {
        guard !kick.started else { return }
        kick.started = true
        await model.refresh()
    }
}

/// The link-a-session sheet: the REAL sessions list in pick mode — same rows,
/// filters and machines grouping as the agents screen. Picking hands back the
/// session's identity without opening it, links it to the plan, and
/// dismisses. Presented by the plan detail screen from its stable sheet
/// level, alongside the comment/task/run sheets.
@available(iOS 26.0, macOS 26.0, *)
public struct PlanSessionLinkPicker: View {
    private let bridge: AgentBridge
    @ObservedObject private var model: RipulSessionListModel
    private let cache: RipulSessionCache
    private let tokenProvider: () -> String?
    private let planKey: String
    @Environment(\.dismiss) private var dismiss

    public init(
        bridge: AgentBridge,
        model: RipulSessionListModel,
        cache: RipulSessionCache,
        tokenProvider: @escaping () -> String?,
        planKey: String
    ) {
        self.bridge = bridge
        self.model = model
        self.cache = cache
        self.tokenProvider = tokenProvider
        self.planKey = planKey
    }

    public var body: some View {
        NavigationStack {
            RipulSessionsView(
                bridge: bridge,
                cache: cache,
                tokenProvider: tokenProvider,
                onSelectSession: { _ in },
                model: model,
                showsTitleLozenge: false,
                onPickUnifiedSession: { session in
                    dismiss()
                    Task {
                        _ = await bridge.planLinkSession(
                            sessionId: session.metadataKey,
                            planKey: planKey,
                            linked: true
                        )
                        await model.refresh()
                    }
                }
            )
            .navigationTitle("Link a session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
