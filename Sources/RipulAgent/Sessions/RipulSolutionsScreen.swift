import SwiftUI

/// Everything the screen needs from its host, bundled so the agent screen
/// stays ignorant of tokens and registries. Built by the host app and handed
/// to `RipulSolutionsScreen`.
public struct RipulSolutionManagement {
    public let registry: RipulToolRegistry
    public let baseURL: URL
    public let tokenProvider: () -> String?
    /// Whether to offer site-key ↔ context assignment. Off for an ordinary SDK
    /// host: a developer curates contexts and collections, but binding them to
    /// keys is a platform-admin act performed from the first-party Ripul app.
    /// (The API gates it too — this only decides whether the row is offered.)
    public let showsSiteKeyAdmin: Bool
    /// Registered app slug for Ripul-hosted OTA builds ("ripul", "wac"). nil
    /// omits the Builds row — a host that doesn't publish builds to Ripul has
    /// nothing to list.
    public let buildsApp: String?

    public init(
        registry: RipulToolRegistry,
        baseURL: URL,
        tokenProvider: @escaping () -> String?,
        showsSiteKeyAdmin: Bool = false,
        buildsApp: String? = nil
    ) {
        self.registry = registry
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.showsSiteKeyAdmin = showsSiteKeyAdmin
        self.buildsApp = buildsApp
    }
}

#if os(iOS)

// ---------------------------------------------------------------------------
// "Solutions" — the developer's solution-shaping controls (collections,
// contexts, testing mode, …), as a screen of their own.
//
// These started in the console DevTools Tools tab, then moved to a disclosure
// panel on the agent screen. Both were the wrong home: every row opens a
// full-screen editor anyway, so the panel was a menu wearing a section's
// clothes, and it grew until it crowded the list whose job is sessions. It is
// a sidebar destination now, reached the same way Files or Plans are.
// ---------------------------------------------------------------------------

public struct RipulSolutionsScreen: View {
    let management: RipulSolutionManagement
    @ObservedObject var bridge: AgentBridge
    /// nil when the host's sidebar is a pinned rail — there is nothing to slide
    /// open, so the bar drops its leading button. Same convention as
    /// `RipulAgentScreenSlots.showingSidebar`.
    var showingSidebar: Binding<Bool>?
    var screenTip: ((String) -> AnyView)?
    /// Set when the screen is PRESENTED rather than navigated to — the SDK
    /// sessions menu's route, where there is no sidebar behind it to go back
    /// to. The bar's leading button becomes a dismiss, and the screen opts out
    /// of the swipe-down switcher: it is a modal detail, not a destination the
    /// overview can return to.
    var onClose: (() -> Void)?

    public init(
        management: RipulSolutionManagement,
        bridge: AgentBridge,
        showingSidebar: Binding<Bool>? = nil,
        screenTip: ((String) -> AnyView)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.management = management
        self.bridge = bridge
        self.showingSidebar = showingSidebar
        self.screenTip = screenTip
        self.onClose = onClose
    }

    @State private var showingCollections = false
    @State private var showingContexts = false
    @State private var showingViewContexts = false
    @State private var showingSiteKeys = false
    @State private var showingModels = false
    @State private var showingUsers = false
    @State private var showingVoiceProfiles = false
    @State private var showingMacros = false
    @State private var showingBuilds = false
    @State private var showingBilling = false
    @State private var showingTheme = false
    /// Phase-2 absorption confirmation + collision alert (moved here from the
    /// console DevTools Tools tab).
    @State private var confirmAbsorption = false
    @State private var absorptionCollisions: [String]?

    public var body: some View {
        rows
            // Opaque, like every other sidebar destination (Files, Dock, CMS
            // Test Bed). Without it the screen is only its glass panel and the
            // app sidebar shows straight through the gaps.
            .background(Color(uiColor: .systemBackground))
            .uiKitIdentifier("RipulSolutionsScreen")
            .ripulTopBarInset {
                GlassTopBar(
                    title: "Solutions",
                    leadingIcon: onClose != nil ? "chevron.down" : "line.3.horizontal",
                    showLeading: showingSidebar != nil || onClose != nil,
                    screenKey: "solutions",
                    screenTip: screenTip,
                    onLeading: {
                        if let onClose { onClose(); return }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showingSidebar?.wrappedValue = true
                        }
                    },
                    switcherEnabled: onClose == nil,
                    menu: { EmptyView() }
                )
            }
            .sheet(isPresented: $showingTheme) {
                RipulThemeManagementScreen(baseURL: management.baseURL, tokenProvider: management.tokenProvider)
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
            .onAppear { consumeMacroDeepLink() }
            .onReceive(NotificationCenter.default.publisher(for: .ripulOpenMacroEditor)) { _ in
                consumeMacroDeepLink()
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
            .sheet(isPresented: $showingViewContexts) {
                NavigationStack {
                    RipulViewContextsScreen(client: RipulViewContextsClient(
                        baseURL: management.baseURL,
                        tokenProvider: management.tokenProvider
                    ))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingViewContexts = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingBuilds) {
                if let app = management.buildsApp {
                    NavigationStack {
                        RipulBuildsScreen(
                            source: .ripulHosted(app: app),
                            baseURL: management.baseURL,
                            tokenProvider: management.tokenProvider
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingBuilds = false }
                            }
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
            .sheet(isPresented: $showingModels) {
                NavigationStack {
                    RipulModelCatalogScreen(
                        client: RipulModelCatalogClient(
                            baseURL: management.baseURL,
                            tokenProvider: management.tokenProvider
                        )
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingModels = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingUsers) {
                NavigationStack {
                    RipulUsersScreen(
                        client: RipulUsersClient(
                            baseURL: management.baseURL,
                            tokenProvider: management.tokenProvider
                        )
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingUsers = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingVoiceProfiles) {
                NavigationStack {
                    VoiceProfilesScreen(
                        baseURL: management.baseURL,
                        tokenProvider: management.tokenProvider
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingVoiceProfiles = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingBilling) {
                NavigationStack {
                    RipulBillingScreen(
                        billingClient: RipulBillingClient(
                            baseURL: management.baseURL,
                            tokenProvider: management.tokenProvider
                        ),
                        siteKeysClient: RipulSiteKeysClient(
                            baseURL: management.baseURL,
                            tokenProvider: management.tokenProvider
                        )
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingBilling = false }
                        }
                    }
                }
            }
            // ripul://billing lands here: notification when already mounted,
            // latch consumed at appear when the deep link beat the mount. The
            // host routes the tab; this only has to open the right sheet.
            .onReceive(NotificationCenter.default.publisher(for: RipulBillingDeepLink.notification)) { _ in
                RipulBillingDeepLink.pending = false
                showingBilling = true
            }
            .onAppear {
                if RipulBillingDeepLink.pending {
                    RipulBillingDeepLink.pending = false
                    showingBilling = true
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

    private var rows: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if !RipulThemeEngine.styleKinds.isEmpty || RipulThemeEngine.remoteTheme != nil {
                    row(title: "Theme", subtitle: "Edit elements and text, then publish to the app",
                        icon: "paintpalette", identifier: "SolutionManagement.theme") { showingTheme = true }
                    Divider().padding(.leading, 44)
                }
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
                    title: "Inspector",
                    subtitle: "Inspect native and web elements; record macros",
                    icon: "viewfinder",
                    identifier: "SolutionManagement.viewExplorer"
                ) {
                    // Collapse the console first, then present over the HOST
                    // window (the explorer inspects the host app, never the
                    // console's own overlay window).
                    if #available(iOS 26.0, *) {
                        RipulDevAssistantOverlay.shared.collapse()
                        RipulViewExplorer.present(in: ScreenElementFinder.hostWindow(), bridge: bridge)
                    }
                }

                Divider().padding(.leading, 44)

                row(
                    title: "Solution Contexts",
                    subtitle: "What a session can do — tools and prompt",
                    icon: "square.stack.3d.up",
                    identifier: "SolutionManagement.contexts"
                ) { showingContexts = true }

                Divider().padding(.leading, 44)
                row(
                    title: "View Contexts",
                    subtitle: "Tabs, chat features, and appearance",
                    icon: "rectangle.3.group",
                    identifier: "SolutionManagement.viewContexts"
                ) { showingViewContexts = true }

                if management.buildsApp != nil {
                    Divider().padding(.leading, 44)
                    row(
                        title: "Builds",
                        subtitle: "Install a published build — history and release notes",
                        icon: "shippingbox",
                        identifier: "SolutionManagement.builds"
                    ) { showingBuilds = true }
                }

                if management.showsSiteKeyAdmin {
                    Divider().padding(.leading, 44)
                    row(
                        title: "Site Keys",
                        subtitle: "Assign contexts to apps — allowed, default, surfaces",
                        icon: "key",
                        identifier: "SolutionManagement.siteKeys"
                    ) { showingSiteKeys = true }

                    Divider().padding(.leading, 44)
                    row(
                        title: "Models",
                        subtitle: "The model catalog — pricing, tiers, defaults",
                        icon: "cube",
                        identifier: "SolutionManagement.models"
                    ) { showingModels = true }

                    Divider().padding(.leading, 44)
                    row(
                        title: "Users",
                        subtitle: "Ripul accounts from Clerk — role, tier, usage",
                        icon: "person.2",
                        identifier: "SolutionManagement.users"
                    ) { showingUsers = true }

                    Divider().padding(.leading, 44)
                    row(
                        title: "Voice Profiles",
                        subtitle: "Speech config site keys bind to — voice, language, terms",
                        icon: "person.wave.2",
                        identifier: "SolutionManagement.voiceProfiles"
                    ) { showingVoiceProfiles = true }

                    Divider().padding(.leading, 44)
                    row(
                        title: "Row Billing",
                        subtitle: "Bill CRM rows via Stripe — account, rules, prices",
                        icon: "creditcard",
                        identifier: "SolutionManagement.billing"
                    ) { showingBilling = true }
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
            .modifier(GlassPanelBackground())
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The replay HUD's return ticket: a finished replay's strip tap deep-
    /// links here — open the library (which then opens the editor for that
    /// exact macro via the same pending value).
    private func consumeMacroDeepLink() {
        guard MacroDeepLink.pendingEditorMacro != nil else { return }
        showingMacros = true
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

// MARK: - Presented route (SDK hosts)

/// Presents `RipulSolutionsScreen` when the sessions menu asks for it.
///
/// The first-party app reaches Solutions through its sidebar
/// (`SidebarTab.solutions`), so it does not use this. An SDK host has no such
/// sidebar: when `f291beca3` moved Solutions out of the sessions list and into
/// a sidebar destination, embedders were left with no route to it at all. The
/// menu row plus this modifier are that route.
///
/// A ViewModifier rather than a `.sheet` on the agent screen's body because
/// that body's modifier chain is already at the type checker's limit — one
/// more inline closure there fails the iOS build outright. Same shape as
/// `AppWorkingDirectorySheet`.
@available(iOS 26.0, *)
public struct SolutionsSheet: ViewModifier {
    let bridge: AgentBridge
    /// nil ⇒ the host offers no Solutions route, and this is inert.
    let management: RipulSolutionManagement?
    @State private var isPresented = false

    public init(bridge: AgentBridge, management: RipulSolutionManagement?) {
        self.bridge = bridge
        self.management = management
    }

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ripulShowSolutions)) { notification in
                // Scoped to the originating bridge, so a second embedded
                // console cannot raise this one's screen.
                guard let source = notification.object as? AgentBridge, source === bridge else { return }
                guard management != nil else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                if let management {
                    RipulSolutionsScreen(
                        management: management,
                        bridge: bridge,
                        // No sidebar behind a sheet — `onClose` turns the bar's
                        // leading button into the dismiss instead.
                        onClose: { isPresented = false }
                    )
                    .ripulSheet(.page)
                }
            }
    }
}
#endif
