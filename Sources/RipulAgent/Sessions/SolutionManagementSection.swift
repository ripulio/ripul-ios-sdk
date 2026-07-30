import SwiftUI

/// Everything the section needs from its host, bundled so GlassSessionsList
/// stays ignorant of tokens and registries. Built by `RipulAgentScreen` from
/// its configuration; absent (nil) on surfaces that shouldn't manage anything.
public struct RipulSolutionManagement {
    public let registry: RipulToolRegistry
    public let baseURL: URL
    public let tokenProvider: () -> String?
    /// Whether to offer site-key ↔ context assignment. Off for an ordinary SDK
    /// host: a developer curates contexts and collections, but binding them to
    /// keys is a platform-admin act performed from the first-party Ripul app.
    /// (The API gates it too — this only decides whether the row is offered.)
    public let showsSiteKeyAdmin: Bool

    public init(
        registry: RipulToolRegistry,
        baseURL: URL,
        tokenProvider: @escaping () -> String?,
        showsSiteKeyAdmin: Bool = false
    ) {
        self.registry = registry
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.showsSiteKeyAdmin = showsSiteKeyAdmin
    }
}

#if os(iOS)

// ---------------------------------------------------------------------------
// "Solution management" — the agent screen's home for the developer's
// solution-shaping controls, rendered as a disclosure panel directly after
// Folders. These controls were previously buried in the console DevTools
// Tools tab; the sessions list is where a developer already lives, so the
// growing set (collections, contexts, testing mode, …) surfaces here.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
struct SolutionManagementSection: View {
    let management: RipulSolutionManagement
    @ObservedObject var bridge: AgentBridge

    @State private var isExpanded = false
    @State private var showingCollections = false
    @State private var showingContexts = false
    @State private var showingSiteKeys = false
    @State private var showingMacros = false
    /// Phase-2 absorption confirmation + collision alert (moved here from the
    /// console DevTools Tools tab).
    @State private var confirmAbsorption = false
    @State private var absorptionCollisions: [String]?

    var body: some View {
        GlassSectionPanel(title: "Solution management", isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                row(
                    title: "Tool Collections",
                    subtitle: "Group tools; agents expand a group on demand",
                    icon: "folder.badge.gearshape",
                    identifier: "SolutionManagement.collections"
                ) { showingCollections = true }

                Divider().padding(.leading, 44)

                row(
                    title: "Macros",
                    subtitle: "Recorded workflows; publish one to make it agent-callable",
                    icon: "record.circle",
                    identifier: "SolutionManagement.macros"
                ) { showingMacros = true }

                Divider().padding(.leading, 44)

                row(
                    title: "Solution Contexts",
                    subtitle: "What a session can do — tools and prompt",
                    icon: "square.stack.3d.up",
                    identifier: "SolutionManagement.contexts"
                ) { showingContexts = true }

                if management.showsSiteKeyAdmin {
                    Divider().padding(.leading, 44)
                    row(
                        title: "Site Keys",
                        subtitle: "Assign contexts to apps — allowed, default, surfaces",
                        icon: "key",
                        identifier: "SolutionManagement.siteKeys"
                    ) { showingSiteKeys = true }
                }

                if bridge.audience == .developer {
                    Divider().padding(.leading, 44)
                    Toggle(isOn: Binding(
                        get: { bridge.isEndUserTestingEnabled },
                        set: { on in
                            if on { confirmAbsorption = true } else { bridge.setEndUserTesting(false) }
                        }
                    )) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.badge.key")
                                .font(.body)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Include end-user tools")
                                    .font(.subheadline.weight(.medium))
                                Text("Lend this dev agent the app's tools — this session only")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .uiKitIdentifier("SolutionManagement.endUserTesting")
                }
            }
        }
        .sheet(isPresented: $showingCollections) {
            NavigationStack {
                RipulToolCollectionsScreen(
                    catalogs: management.registry.editorCatalogs()
                        + [.developer(bridge.registeredToolSummaries)],
                    tokenProvider: management.tokenProvider
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingCollections = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingMacros) {
            MacroLibraryScreen(
                client: RipulMacroClient(baseURL: management.baseURL, tokenProvider: management.tokenProvider),
                onChange: {
                    Task {
                        await MacroRegistrySync.refresh(
                            client: RipulMacroClient(baseURL: management.baseURL, tokenProvider: management.tokenProvider),
                            registry: management.registry
                        )
                    }
                }
            )
        }
        .sheet(isPresented: $showingContexts) {
            NavigationStack {
                RipulSolutionContextsScreen(
                    client: RipulSolutionContextsClient(
                        baseURL: management.baseURL,
                        tokenProvider: management.tokenProvider
                    ),
                    sources: RipulContextToolSources(
                        collections: { [management] in
                            let client = RipulToolCollectionsClient(
                                baseURL: management.baseURL,
                                tokenProvider: management.tokenProvider
                            )
                            return (try? await client.list().map(\.name)) ?? []
                        },
                        catalogs: { [management, bridge] in
                            management.registry.editorCatalogs()
                                + [.developer(bridge.registeredToolSummaries)]
                        }
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingContexts = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSiteKeys) {
            NavigationStack {
                RipulSiteKeysScreen(
                    siteKeysClient: RipulSiteKeysClient(
                        baseURL: management.baseURL,
                        tokenProvider: management.tokenProvider
                    ),
                    contextsClient: RipulSolutionContextsClient(
                        baseURL: management.baseURL,
                        tokenProvider: management.tokenProvider
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingSiteKeys = false }
                    }
                }
            }
        }
        .confirmationDialog(
            "Include end-user tools?",
            isPresented: $confirmAbsorption,
            titleVisibility: .visible
        ) {
            Button("Include for this session", role: .destructive) {
                if case .blocked(let names) = bridge.setEndUserTesting(true) {
                    absorptionCollisions = names
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Side-effect honesty (phase 2 §4): never masquerade as a sandbox.
            Text("These tools act on this device's real data — pickers present real UI, create/update tools write real records. The setting resets when this session ends.")
        }
        .alert(
            "Name collision",
            isPresented: Binding(
                get: { absorptionCollisions != nil },
                set: { if !$0 { absorptionCollisions = nil } }
            )
        ) {
            Button("OK", role: .cancel) { absorptionCollisions = nil }
        } message: {
            Text("A developer tool and an end-user tool share a name, so the sets cannot be merged: \((absorptionCollisions ?? []).joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String,
        icon: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiKitIdentifier(identifier)
    }
}
#endif
